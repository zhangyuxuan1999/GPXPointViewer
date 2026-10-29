"""Local Git metadata bounds and explicit generated-source watch regressions."""
import json,os,signal,subprocess,sys,time,unittest
from pathlib import Path
from unittest.mock import patch
sys.path.insert(0,str(Path(__file__).resolve().parents[2]/"Tools/agents"))
import run_store
from run_store import RunStore
from helpers import REPO,fresh_evidence,archive_evidence,init_repo,invoke,sha256

class GitMetadataCase(unittest.TestCase):
    def setUp(self):
        self.evidence=fresh_evidence(self._testMethodName)
        self.cwd=self.evidence/"workspace";self.cwd.mkdir()
        self.task=self.evidence/"task.md";self.task.write_text("Offline Git metadata fixture. No API/app.\n")
    def tearDown(self):
        archive_evidence(self.evidence)
    def create(self,**kwargs):
        return RunStore.create(kwargs.pop("root",self.evidence/"records"),"git-metadata",self.task,
            cwd=self.cwd,watch=kwargs.pop("watch",["."]),**kwargs)
    def fake_env(self,mode):
        bindir=self.evidence/"bin";bindir.mkdir(exist_ok=True)
        git=bindir/"git";git.write_bytes((Path(__file__).parent/"fixtures/mock_git.py").read_bytes());git.chmod(0o755)
        return {"PATH":str(bindir)+os.pathsep+os.environ.get("PATH",os.defpath),
                "MOCK_GIT_MODE":mode,"MOCK_GIT_PID_DIR":str(self.evidence/"pids")}
    def metadata(self,run,label="after"):
        return json.loads((run.path/"snapshots"/label/"git.json").read_text())
    def assert_dead(self,pid):
        deadline=time.monotonic()+3
        while time.monotonic()<deadline:
            try:os.kill(pid,0)
            except ProcessLookupError:return
            time.sleep(0.02)
        self.fail("own fake Git process still exists: "+str(pid))
    def test_hang_retains_partial_output_reaps_group_and_leaves_unrelated_process(self):
        (self.cwd/"source.txt").write_text("snapshot survives\n")
        run=self.create()
        sentinel=subprocess.Popen([sys.executable,"-c","import time; time.sleep(3600)"],start_new_session=True)
        try:
            with patch.dict(os.environ,self.fake_env("hang-status")),patch.object(run_store,"GIT_METADATA_TOTAL_SECONDS",1.5),patch.object(run_store,"GIT_METADATA_COMMAND_SECONDS",0.4):
                t0=time.monotonic();run.snapshot("after");elapsed=time.monotonic()-t0
            git=self.metadata(run)
            self.assertLess(elapsed,2.5)
            self.assertEqual(git["status"]["status"],"timeout")
            self.assertTrue(git["status"]["timed_out"])
            self.assertEqual(git["status"]["exit_code"],-signal.SIGKILL)
            text=(run.path/"snapshots/after/status.txt").read_text()
            self.assertIn("NORMAL_STDOUT_status",text);self.assertIn("NORMAL_STDERR_status",text)
            self.assertIn("CHILD_PARTIAL_OUTPUT",text)
            self.assertFalse(git["_meta"]["complete"])
            self.assertEqual(git["status"]["argv"][0],"git")
            self.assertGreater(git["status"]["duration_seconds"],0)
            pids=json.loads((self.evidence/"pids/status.json").read_text())
            self.assert_dead(pids["leader"]);self.assert_dead(pids["child"])
            self.assertIsNone(sentinel.poll(),"unrelated process was signalled")
            self.assertIn("source.txt",json.loads((run.path/"snapshots/after/manifest.json").read_text())["files"])
        finally:
            sentinel.kill();sentinel.wait(timeout=3)
    def test_total_deadline_marks_unattempted_commands_unknown_not_clean(self):
        run=self.create()
        with patch.dict(os.environ,self.fake_env("hang")),patch.object(run_store,"GIT_METADATA_TOTAL_SECONDS",0.5),patch.object(run_store,"GIT_METADATA_COMMAND_SECONDS",0.2):
            t0=time.monotonic();run.snapshot("after");elapsed=time.monotonic()-t0
        git=self.metadata(run)
        self.assertLess(elapsed,1.5)
        records=[v for k,v in git.items() if k!="_meta"]
        skipped=[r for r in records if r["status"]=="skipped"]
        self.assertTrue(skipped)
        for rec in skipped:
            self.assertFalse(rec["attempted"]);self.assertIsNone(rec["exit_code"])
            self.assertIn("budget exhausted",rec["error"])
            self.assertIn("Git metadata skipped",(run.path/"snapshots/after"/rec["path"]).read_text())
        for p in (self.evidence/"pids").glob("*.json"):
            pids=json.loads(p.read_text());self.assert_dead(pids["leader"]);self.assert_dead(pids["child"])
    def test_missing_git_keeps_changes_and_successful_provider_terminal(self):
        (self.cwd/"source.txt").write_text("before")
        run=self.create(allow_write=["source.txt"])
        with patch.object(run_store.subprocess,"Popen",side_effect=FileNotFoundError("synthetic missing git")):
            run.snapshot("before");(self.cwd/"source.txt").write_text("after");changes=run.snapshot("after")
        self.assertEqual(changes["modified"],["source.txt"])
        git=self.metadata(run)
        self.assertFalse(git["_meta"]["complete"])
        self.assertEqual(git["head"]["status"],"unavailable");self.assertIsNone(git["head"]["exit_code"])
        result=run.finish({"provider_status":"succeeded","acceptance_status":"pending"},output="real report despite unavailable metadata")
        self.assertEqual(result["run_status"],"succeeded")
        self.assertEqual(result["verification_status"],"not_run")
    def test_nonrepo_and_nonzero_git_keep_explicit_error_evidence(self):
        run=self.create();run.snapshot("before")
        git=self.metadata(run,"before")
        self.assertEqual(git["head"]["status"],"error");self.assertEqual(git["head"]["exit_code"],128)
        self.assertIn("not a git repository",(run.path/"snapshots/before/head.txt").read_text())
        with patch.dict(os.environ,self.fake_env("error")):run.snapshot("after")
        git=self.metadata(run)
        for key,rec in git.items():
            if key=="_meta":continue
            self.assertEqual(rec["exit_code"],23);self.assertEqual(rec["status"],"error")
            text=(run.path/"snapshots/after"/rec["path"]).read_text()
            self.assertIn("NORMAL_STDOUT_",text);self.assertIn("NORMAL_STDERR_",text)
    def test_scoped_git_keeps_staged_untracked_deleted_without_index_or_config_mutation(self):
        git=init_repo(self.cwd)
        src=self.cwd/"src";src.mkdir()
        for name in ("staged.txt","deleted.txt"):(src/name).write_text("original\n")
        git("add","src");git("-c","user.email=offline@example.invalid","-c","user.name=Offline","commit","-qm","scoped fixture")
        (src/"staged.txt").write_text("STAGED SCOPED CHANGE\n");git("add","src/staged.txt")
        (src/"untracked[1].txt").write_text("UNTRACKED SCOPED\n")
        (self.cwd/"outside-untracked.txt").write_text("outside\n")
        records=self.cwd/"Tools/agents/records/history";records.mkdir(parents=True);(records/"unrelated-history.txt").write_text("history\n")
        hook=self.evidence/"should-not-run";marker=self.evidence/"unexpected-fsmonitor"
        hook.write_text("#!/usr/bin/env python3\nfrom pathlib import Path\nPath("+repr(str(marker))+").write_text('unexpected')\n");hook.chmod(0o755)
        git("config","core.fsmonitor",str(hook))
        index_before=(self.cwd/".git/index").read_bytes();config_before=(self.cwd/".git/config").read_bytes()
        run=self.create(watch=["src","Tools"],allow_write=["src"]);run.snapshot("before")
        (src/"deleted.txt").unlink();changes=run.snapshot("after")
        self.assertEqual(changes["deleted"],["src/deleted.txt"])
        receipt=self.metadata(run)
        self.assertTrue(receipt["_meta"]["complete"])
        text="\n".join((run.path/"snapshots/after"/v["path"]).read_text() for k,v in receipt.items() if k!="_meta")
        self.assertIn("src/staged.txt",text);self.assertIn("src/deleted.txt",text);self.assertIn("src/untracked[1].txt",text)
        self.assertNotIn("outside-untracked",text);self.assertNotIn("unrelated-history",text)
        self.assertFalse(marker.exists())
        self.assertEqual((self.cwd/".git/index").read_bytes(),index_before)
        self.assertEqual((self.cwd/".git/config").read_bytes(),config_before)
    def test_literal_watch_and_explicit_records_do_not_expand_to_siblings(self):
        git=init_repo(self.cwd)
        selected=":selected[1].txt";(self.cwd/selected).write_text("selected\n")
        (self.cwd/":selected1.txt").write_text("sibling\n")
        run=self.create(watch=[selected]);run.snapshot("before")
        receipt=self.metadata(run,"before");text=(run.path/"snapshots/before/untracked.txt").read_text()
        self.assertIn(selected,text);self.assertNotIn(":selected1.txt",text)
        rel="Tools/agents/records/batch/work";work=self.cwd/rel;work.mkdir(parents=True)
        (work/"tracked.txt").write_text("tracked before\n");(work/"deleted.txt").write_text("delete before\n")
        git("add",rel);git("-c","user.email=offline@example.invalid","-c","user.name=Offline","commit","-qm","explicit records fixture")
        (work/"tracked.txt").write_text("staged after\n");git("add",rel+"/tracked.txt")
        (work/"untracked.txt").write_text("untracked source\n")
        sibling=work.parent/"unrelated-history.txt";sibling.write_text("history\n")
        (work/".aws").mkdir();(work/".aws/private.txt").write_text("PUBLIC SYNTHETIC SENSITIVE CANARY\n")
        (work/"excluded").mkdir();(work/"excluded/private.txt").write_text("user excluded\n")
        run=self.create(root=work/"own-logs",watch=["Tools",rel],allow_write=[rel],exclude=[rel+"/excluded"])
        meta=run.meta;self.assertEqual(meta["snapshot_exclusions"]["explicit_overrides"],[rel])
        run.snapshot("before");(work/"tracked.txt").write_text("modified after\n");(work/"deleted.txt").unlink();(work/"new.txt").write_text("new after\n")
        changes=run.snapshot("after")
        self.assertIn(rel+"/new.txt",changes["added"]);self.assertIn(rel+"/deleted.txt",changes["deleted"]);self.assertIn(rel+"/tracked.txt",changes["modified"])
        manifest=json.loads((run.path/"snapshots/after/manifest.json").read_text())["files"]
        self.assertIn(rel+"/untracked.txt",manifest)
        self.assertFalse(any(".aws" in p or "/excluded/" in p or "unrelated-history" in p or run.path.name in p for p in manifest))
        receipt=self.metadata(run)
        self.assertIn("status_explicit",receipt)
        text="\n".join((run.path/"snapshots/after"/v["path"]).read_text() for k,v in receipt.items() if k!="_meta")
        for name in ("tracked.txt","untracked.txt","deleted.txt","new.txt"):self.assertIn(rel+"/"+name,text)
        self.assertNotIn("unrelated-history",text);self.assertNotIn(".aws/private",text);self.assertNotIn("excluded/private",text);self.assertNotIn(run.path.name,text)
    def test_allow_write_override_user_exclude_priority_and_default_history_exclusion(self):
        rel="Tools/agents/records/batch/work";work=self.cwd/rel;work.mkdir(parents=True)
        (work/"source.txt").write_text("source\n")
        default=self.create(watch=["Tools"]);default.snapshot("before")
        self.assertEqual(json.loads((default.path/"snapshots/before/manifest.json").read_text())["files"],{})
        explicit=self.create(watch=["Tools"],allow_write=[rel]);explicit.snapshot("before")
        self.assertIn(rel+"/source.txt",json.loads((explicit.path/"snapshots/before/manifest.json").read_text())["files"])
        excluded=self.create(watch=[rel],allow_write=[rel],exclude=["Tools/agents/records"]);excluded.snapshot("before")
        self.assertEqual(json.loads((excluded.path/"snapshots/before/manifest.json").read_text())["files"],{})
    def test_explicit_root_exclusion_remains_stronger_than_generated_override(self):
        rel="Tools/agents/records/batch/work";work=self.cwd/rel;work.mkdir(parents=True)
        (work/"source.txt").write_text("source\n")
        run=self.create(watch=[rel],allow_write=[rel],exclude=["."]);run.snapshot("before")
        self.assertEqual(json.loads((run.path/"snapshots/before/manifest.json").read_text())["files"],{})
    def test_empty_watch_does_not_fall_back_to_unscoped_git(self):
        run=self.create(watch=[])
        with patch.dict(os.environ,self.fake_env("success")):run.snapshot("after")
        receipt=self.metadata(run)
        self.assertEqual(receipt["head"]["status"],"ok")
        for key in ("status","unstaged","staged","untracked"):
            self.assertFalse(receipt[key]["attempted"]);self.assertIn("empty watch",receipt[key]["error"])
    def test_real_cli_finish_is_bounded_and_success_survives_git_timeout(self):
        self.assertLessEqual(run_store.GIT_METADATA_TOTAL_SECONDS,15)
        self.assertLessEqual(run_store.GIT_METADATA_COMMAND_SECONDS,5)
        (self.cwd/"source.txt").write_text("source\n")
        run=self.create();report=self.evidence/"report.md";report.write_text("Real native report. Git optional.\n")
        case=self.evidence/"cli";case.mkdir()
        command=[sys.executable,str(REPO/"Tools/agents/agent_run.py"),"finish",str(run.path),"--provider-status","succeeded","--acceptance","pending","--output",str(report)]
        t0=time.monotonic();proc=invoke(command,env=self.fake_env("hang-status"),timeout=8,evidence=case);elapsed=time.monotonic()-t0
        self.assertEqual(proc.returncode,0,proc.stdout+proc.stderr);self.assertLess(elapsed,7)
        result=json.loads((run.path/"result.json").read_text());self.assertEqual(result["provider_status"],"succeeded");self.assertEqual(result["acceptance_status"],"pending")
        self.assertTrue(self.metadata(run)["status"]["timed_out"])
        pids=json.loads((self.evidence/"pids/status.json").read_text());self.assert_dead(pids["leader"]);self.assert_dead(pids["child"])

if __name__=="__main__":unittest.main(verbosity=2)
