"""Deterministic OS-refusal injection: cleanup must not erase terminal evidence."""
import asyncio,contextlib,errno,io,json,os,queue,signal,subprocess,sys,time,types,unittest
from pathlib import Path
from unittest.mock import patch
sys.path.insert(0,str(Path(__file__).resolve().parents[2]/"Tools/agents"))
import agent_run,api_run
from run_store import RunStore,atomic_json
from helpers import REPO,MOCK,fresh_evidence,archive_evidence,invoke

class FakeWorker:
    pid=2100000001
    def __init__(self,run,final,alive=True,faults=(),query_completed=True):
        self.run,self.final,self.alive,self.faults=run,final,alive,set(faults)
        self.query_completed=query_completed
        self.exitcode=None if alive else 0
        self.calls=[]
    def start(self):
        atomic_json(self.run.path/"sdk-worker-result.json",{"final":self.final,"error":None,"query_completed":self.query_completed})
        atomic_json(self.run.path/"sdk-worker-owner.json",{"pid":self.pid,"process_group":self.pid,"session_id":self.pid,"process_identity":"fixture-start"})
    def is_alive(self):return self.alive
    def join(self,timeout=None):
        self.calls.append(("join",timeout))
        if "join" in self.faults:raise PermissionError(errno.EPERM,"injected direct join refusal")
    def terminate(self):
        self.calls.append(("terminate",None))
        if "terminate" in self.faults:raise PermissionError(errno.EPERM,"injected direct terminate refusal")
        self.alive=False;self.exitcode=-signal.SIGTERM
    def kill(self):
        self.calls.append(("kill",None))
        if "kill" in self.faults:raise PermissionError(errno.EPERM,"injected direct kill refusal")
        self.alive=False;self.exitcode=-signal.SIGKILL

class ProcessCleanupCase(unittest.TestCase):
    def setUp(self):
        self.evidence=fresh_evidence(self._testMethodName)
        self.cwd=self.evidence/"workspace";self.cwd.mkdir()
        (self.cwd/"source.txt").write_text("primary snapshot fixture\n")
        self.task=self.evidence/"task.md";self.task.write_text("Offline cleanup refusal fixture.\n")
        self.config=self.evidence/"config.json";self.config.write_text(json.dumps({"capacity_usd":10,"source":"public offline fixture"}))
    def tearDown(self):archive_evidence(self.evidence)
    def sdk(self,*,scenario="turns",alive=True,faults=(),group="denied",helper_raises=False,cost=0.25,query_completed=True):
        records=self.evidence/("records-"+str(len(list(self.evidence.glob("records-*")))))
        run=RunStore.create(records,"cleanup-fixture",self.task,cwd=self.cwd,watch=["."]);run.snapshot("before")
        subtype={"turns":"error_max_turns","budget":"error_max_budget_usd"}.get(scenario,"success")
        final={"message_class":"ResultMessage","subtype":subtype,"is_error":subtype!="success","terminal_reason":"completed" if subtype=="success" else scenario,"result":"PUBLIC_FIXTURE_FINAL","total_cost_usd":cost,"num_turns":2}
        worker=FakeWorker(run,final,alive,faults,query_completed)
        real_pg,real_sid,real_identity=os.getpgid,os.getsid,agent_run.process_identity
        def pg(pid):return (os.getpgrp() if group=="parent" else pid) if pid==worker.pid else real_pg(pid)
        def sid(pid):return pid if pid==worker.pid else real_sid(pid)
        def identity(pid):return "fixture-start" if pid==worker.pid else real_identity(pid)
        def killpg(pid,sig):
            self.assertEqual(pid,worker.pid,"cleanup signalled a group outside its own child")
            if group in {"absent","parent"}:raise ProcessLookupError(errno.ESRCH,"injected absent child group")
            raise PermissionError(errno.EPERM,"injected group refusal")
        ledger=records/"budget.json"
        args=["cleanup-fixture",str(self.task),"--model","fixture-model","--budget","2","--budget-config",str(self.config),"--ledger",str(ledger),"--records-root",str(records),"--cwd",str(self.cwd),"--watch",".","--timeout","0.001" if alive else "2"]
        output=io.StringIO();t0=time.monotonic()
        with contextlib.ExitStack() as stack:
            stack.enter_context(patch.object(api_run,"register",return_value=(run,"",None)))
            stack.enter_context(patch.object(api_run.multiprocessing,"get_context",return_value=types.SimpleNamespace(Process=lambda **kw:worker)))
            stack.enter_context(patch.dict(os.environ,{"ANTHROPIC_API_KEY":"PUBLIC_SYNTHETIC_OFFLINE_CANARY_NOT_A_KEY"}))
            stack.enter_context(patch.object(agent_run,"process_identity",side_effect=identity))
            stack.enter_context(patch.object(os,"getpgid",side_effect=pg));stack.enter_context(patch.object(os,"getsid",side_effect=sid))
            stack.enter_context(patch.object(os,"killpg",side_effect=killpg))
            if helper_raises:stack.enter_context(patch.object(api_run,"_stop_worker",side_effect=PermissionError(errno.EPERM,"injected helper escape")))
            stack.enter_context(contextlib.redirect_stdout(output));rc=api_run.main(args)
        (run.path/"fixture-stdout.txt").write_text(output.getvalue())
        (run.path/"fixture-command.json").write_text(json.dumps({"argv":args,"exit_code":rc,"duration_s":time.monotonic()-t0},indent=2))
        result=json.loads((run.path/"result.json").read_text());events=[json.loads(x) for x in (run.path/"events.jsonl").read_text().splitlines()]
        self.assertTrue((run.path/"snapshots/after/manifest.json").exists());self.assertTrue((run.path/"output.md").read_text().strip())
        row=json.loads(ledger.read_text())["runs"][run.meta["run_id"]]
        self.assertIn("budget_settled",[x["type"] for x in events]);self.assertIn("process_cleanup",[x["type"] for x in events])
        expected_cost=cost if query_completed else None
        self.assertEqual(row["cost_usd"],expected_cost);self.assertIsNone(result["actual_billed_cost_usd"])
        self.assertEqual(result["runner_exit_code"],rc);self.assertEqual(result["exit_code"],rc)
        return rc,result,row,worker,run
    def test_sdk_killpg_eperm_keeps_final_timeout_snapshots_settlement_and_exit(self):
        rc,result,row,worker,run=self.sdk()
        self.assertEqual(rc,124);self.assertEqual(result["provider_status"],"interrupted")
        self.assertEqual(result["runner_terminal_reason"],"wall_clock_timeout");self.assertEqual(result["subtype"],"error_max_turns")
        self.assertEqual(result["cost_usd"],0.25);self.assertEqual(row["status"],"settled")
        self.assertFalse(result["cleanup_complete"])
        self.assertTrue(any(e.get("errno")==errno.EPERM for e in result["process_cleanup"][0]["errors"]))
    def test_sdk_structured_turn_and_budget_reasons_survive_cleanup_refusal(self):
        for scenario in ("turns","budget"):
            with self.subTest(scenario=scenario):
                rc,result,_,_,_=self.sdk(scenario=scenario,alive=False)
                self.assertEqual(rc,1);self.assertEqual(result["provider_status"],"interrupted")
                self.assertEqual(result["terminal_reason"],scenario);self.assertIsNone(result["runner_terminal_reason"])
                self.assertFalse(result["cleanup_complete"])
    def test_sdk_direct_terminate_kill_and_join_errors_are_isolated(self):
        for faults in [("terminate",),("terminate","kill"),("join",)]:
            with self.subTest(faults=faults):
                rc,result,_,worker,_=self.sdk(faults=faults)
                self.assertEqual(rc,124);self.assertEqual(result["provider_status"],"interrupted")
                errors=result["process_cleanup"][0]["errors"]
                for method in faults:self.assertTrue(any(method in e["operation"] or method=="join" and e["operation"]=="wait" for e in errors),errors)
                self.assertTrue(all(timeout is None or timeout<=0.5 for _,timeout in worker.calls))
    def test_sdk_unexpected_helper_exception_cannot_skip_finalization(self):
        rc,result,row,_,_=self.sdk(helper_raises=True)
        self.assertEqual(rc,124);self.assertEqual(row["cost_usd"],0.25)
        self.assertFalse(result["cleanup_complete"]);self.assertEqual(result["process_cleanup"][0]["errors"][0]["operation"],"cleanup_helper")
    def test_sdk_unknown_cost_still_retains_reservation_after_refused_cleanup(self):
        rc,result,row,_,_=self.sdk(cost=None)
        self.assertEqual(rc,124);self.assertIsNone(result["cost_usd"]);self.assertEqual(row["status"],"unknown_cost_hold")
    def test_incomplete_query_and_refused_cleanup_keep_budget_hold(self):
        rc,result,row,_,_=self.sdk(query_completed=False,faults=("terminate","kill"))
        self.assertEqual(rc,124);self.assertIsNone(result["cost_usd"])
        self.assertEqual(result["sdk_reported_cost_usd"],0.25)
        self.assertFalse(result["sdk_query_completed"]);self.assertEqual(row["status"],"unknown_cost_hold")
    def test_exited_worker_absent_group_is_confirmed_without_spurious_error(self):
        rc,result,_,worker,_=self.sdk(scenario="success",alive=False,group="absent")
        self.assertEqual(rc,0);self.assertTrue(result["cleanup_complete"])
        self.assertEqual(result["process_cleanup"][0]["errors"],[])
    def test_worker_before_setsid_never_targets_parent_group(self):
        rc,result,_,worker,_=self.sdk(group="parent")
        self.assertEqual(rc,124)
        mutations=[x for x in result["process_cleanup"][0]["attempts"] if x["operation"] in {"group_sigterm","group_sigkill"}]
        self.assertTrue(all(x["outcome"]=="skipped_unverified_group" for x in mutations))
        self.assertIn(("terminate",None),worker.calls)
    def test_reused_identity_prevents_any_mutating_signal(self):
        run=RunStore.create(self.evidence/"fake", "ownership",self.task,cwd=self.cwd,watch=[])
        worker=FakeWorker(run,{},alive=True)
        owner={"pid":worker.pid,"parent_pid":os.getpid(),"process_identity":"original-start","group_created":True}
        with patch.object(agent_run,"process_identity",return_value="reused-start"),patch.object(os,"killpg") as signal_mock:
            receipt=agent_run.terminate_group(worker,owner=owner)
        self.assertFalse(signal_mock.called);self.assertNotIn(("terminate",None),worker.calls);self.assertNotIn(("kill",None),worker.calls)
        self.assertEqual(receipt["status"],"incomplete");self.assertTrue(any(e["type"]=="IdentityMismatch" for e in receipt["errors"]))
    def test_reaped_pid_with_unverifiable_identity_never_signals_reused_group(self):
        class Reaped:
            pid=2100000002;returncode=0
            def poll(self):return 0
            def wait(self,timeout):return 0
            def terminate(self):raise AssertionError("reaped child cannot be terminated")
            def kill(self):raise AssertionError("reaped child cannot be killed")
        for expected,current in [(None,None),("original-start",None),(None,"new-start")]:
            with self.subTest(expected=expected,current=current):
                proc=Reaped();owner={"pid":proc.pid,"parent_pid":os.getpid(),"process_identity":expected,"group_created":True}
                with patch.object(agent_run,"process_identity",return_value=current),patch.object(os,"getpgid",return_value=proc.pid),patch.object(os,"getsid",return_value=proc.pid),patch.object(os,"killpg") as mutate:
                    receipt=agent_run.terminate_group(proc,owner=owner)
                self.assertFalse(mutate.called);self.assertEqual(receipt["status"],"incomplete");self.assertIsNone(receipt["group_alive"])
    def test_live_unreaped_direct_child_can_use_safe_fallback_when_identity_unavailable(self):
        class Live:
            pid=2100000003;returncode=None
            def poll(self):return self.returncode
            def wait(self,timeout):return self.returncode
            def terminate(self):self.returncode=-15
            def kill(self):self.returncode=-9
        proc=Live();owner={"pid":proc.pid,"parent_pid":os.getpid(),"process_identity":None,"group_created":True};calls=[]
        def mutate(pid,sig):
            calls.append((pid,sig))
            if sig==signal.SIGTERM:proc.returncode=-15
        with patch.object(agent_run,"process_identity",return_value=None),patch.object(os,"getpgid",return_value=proc.pid),patch.object(os,"getsid",return_value=proc.pid),patch.object(os,"killpg",side_effect=mutate):
            receipt=agent_run.terminate_group(proc,owner=owner)
        self.assertEqual(calls,[(proc.pid,signal.SIGTERM)])
        self.assertEqual(receipt["status"],"incomplete")
    def deepseek_refusal(self,helper=False):
        records=self.evidence/"ds-records";created=[];real_popen=subprocess.Popen
        def deny(*a,**kw):raise PermissionError(errno.EPERM,"injected cleanup denial")
        def capture(*a,**kw):
            proc=real_popen(*a,**kw)
            if a and str(a[0][0])==str(MOCK):
                created.append(proc)
                if not helper:
                    proc.terminate=deny;proc.kill=deny
            return proc
        args=["deepseek","cleanup-denied",str(self.task),"--records-root",str(records),"--cwd",str(self.cwd),"--watch",".","--cli",str(MOCK),"--max-turns","2","--timeout","0.15"]
        out=io.StringIO();t0=time.monotonic()
        try:
            with contextlib.ExitStack() as stack:
                stack.enter_context(patch.object(agent_run.subprocess,"Popen",side_effect=capture))
                stack.enter_context(patch.dict(os.environ,{"MOCK_SCENARIO":"timeout"}))
                if helper:stack.enter_context(patch.object(agent_run,"terminate_group",side_effect=deny))
                else:stack.enter_context(patch.object(os,"killpg",side_effect=deny))
                stack.enter_context(contextlib.redirect_stdout(out));rc=agent_run.main(args)
            elapsed=time.monotonic()-t0
            run=next(records.glob("*/meta.json")).parent;result=json.loads((run/"result.json").read_text())
            (run/"fixture-command.json").write_text(json.dumps({"argv":args,"exit_code":rc,"duration_s":elapsed},indent=2));(run/"fixture-stdout.txt").write_text(out.getvalue())
            self.assertEqual(rc,124);self.assertEqual(result["runner_exit_code"],124);self.assertEqual(result["provider_status"],"interrupted")
            self.assertEqual(result["runner_terminal_reason"],"wall_clock_timeout");self.assertFalse(result["cleanup_complete"])
            self.assertTrue(result["stream_incomplete"]);self.assertLess(elapsed,3)
            self.assertIsNone(result["cost_usd"]);self.assertTrue((run/"snapshots/after/manifest.json").exists())
            self.assertIn("_END_NORMAL",(run/"transcript.jsonl").read_text())
            self.assertTrue(any(p.poll() is None for p in created),"fixture did not force an unconfirmed live child")
        finally:
            for proc in created:
                if proc.poll() is None:
                    self.assertEqual(os.getpgid(proc.pid),proc.pid)
                    os.killpg(proc.pid,signal.SIGKILL);proc.wait(timeout=3)
    def test_deepseek_all_signal_refusals_have_bounded_drain_and_keep_timeout_exit(self):self.deepseek_refusal()
    def test_deepseek_unexpected_cleanup_helper_escape_is_contained(self):self.deepseek_refusal(helper=True)
    def test_additional_signals_never_reset_drain_deadline_or_primary_timeout(self):
        folder=self.evidence/"signal-model";folder.mkdir();task=folder/"task.md";task.write_text("Offline signal clock model.\n")
        class Run:
            path=folder;meta={}
            def __init__(self):self.events=[];self.result=None
            def event(self,kind,**kwargs):self.events.append({"type":kind,**kwargs})
            def bind(self,**kwargs):pass
            def snapshot(self,label):return {"out_of_scope":[]}
            def finish(self,result,output):self.result=result
        run=Run();clock=[0.0];handlers={};calls=[]
        class Pipe:
            def close(self):pass
        class Process:
            pid=2100000004;returncode=None;stdout=Pipe();stderr=Pipe()
            def wait(self,timeout=None):self.returncode=0;return 0
        class Thread:
            def __init__(self,**kwargs):pass
            def start(self):pass
        class Messages:
            def __init__(self,maxsize):self.maxsize=maxsize;self.i=0
            def get(self,timeout):
                self.i+=1;clock[0]+=0.2
                if 2<=self.i<=20:handlers[signal.SIGTERM](signal.SIGTERM,None)
                if self.i==21:return ("stdout",None)
                if self.i==22:return ("stderr",None)
                raise queue.Empty()
            def get_nowait(self):raise queue.Empty()
        def register_handler(sig,handler):handlers[sig]=handler;return signal.SIG_DFL
        def cleanup(*a,**kw):
            calls.append(clock[0]);return {"status":"incomplete","leader_alive":True,"group_alive":True,"leader_exit_code":None,"attempts":[],"errors":[{"operation":"fixture","type":"PermissionError"}]}
        args=types.SimpleNamespace(resume_mode="context",max_turns=2,timeout=0.1,task=task,cwd=folder)
        with patch.object(agent_run,"register",return_value=(run,"",None)),patch.object(agent_run,"build_deepseek_command",return_value=["offline-no-executable"]),patch.object(agent_run.subprocess,"Popen",return_value=Process()),patch.object(agent_run,"process_owner",return_value={"process_identity":"fixture"}),patch.object(agent_run,"terminate_group",side_effect=cleanup),patch.object(agent_run.threading,"Thread",Thread),patch.object(agent_run.queue,"Queue",Messages),patch.object(agent_run.time,"monotonic",side_effect=lambda:clock[0]),patch.object(agent_run.signal,"signal",side_effect=register_handler):
            code=agent_run.run_deepseek(args)
        self.assertEqual(code,124);self.assertEqual(len(calls),1)
        self.assertLessEqual(clock[0],calls[0]+agent_run.CLEANUP_DRAIN_SECONDS+0.21)
        self.assertTrue(run.result["stream_incomplete"]);self.assertEqual(run.result["runner_terminal_reason"],"wall_clock_timeout")
        self.assertEqual(sum(e["type"]=="termination_requested" for e in run.events),1)
        self.assertTrue(any(e["type"]=="additional_termination_requested" for e in run.events))
        (folder/"model-result.json").write_text(json.dumps({"runner_code":code,"virtual_seconds":clock[0],"cleanup_calls":len(calls),"events":run.events},indent=2))
    def test_pipe_eof_before_child_exit_still_obeys_original_wall_timeout(self):
        cli=self.evidence/"close-pipes-cli.py"
        cli.write_text("#!/usr/bin/env python3\nimport os,time\nos.close(1);os.close(2);time.sleep(10)\n");cli.chmod(0o755)
        case=self.evidence/"eof-before-exit";case.mkdir()
        args=[sys.executable,str(REPO/"Tools/agents/agent_run.py"),"deepseek","early-eof",str(self.task),"--records-root",str(case/"records"),"--cwd",str(self.cwd),"--watch",".","--cli",str(cli),"--max-turns","2","--timeout","0.8"]
        t0=time.monotonic();proc=invoke(args,timeout=3,evidence=case);elapsed=time.monotonic()-t0
        self.assertEqual(proc.returncode,124,proc.stdout+proc.stderr);self.assertLess(elapsed,2)
        run=next((case/"records").glob("*/result.json")).parent;result=json.loads((run/"result.json").read_text())
        self.assertTrue(result["interrupted"]);self.assertEqual(result["runner_terminal_reason"],"wall_clock_timeout")
        self.assertEqual(result["provider_status"],"interrupted");self.assertEqual(result["runner_exit_code"],124)
        self.assertFalse(result["stream_incomplete"])
    def test_refused_real_worker_cleanup_cannot_trigger_runtime_unbounded_join(self):
        script=self.evidence/"runtime-exit.py"
        script.write_text("import errno,json,multiprocessing,multiprocessing.util,os,signal,sys,time\nfrom pathlib import Path\nfrom unittest.mock import patch\nsys.path.insert(0,"+repr(str(REPO/"Tools/agents"))+")\nimport api_run,agent_run\n"
            +"def child(ready):\n os.setsid();Path(ready).write_text('ready');time.sleep(10)\n"
            +"if __name__=='__main__':\n ready=Path(__file__).with_suffix('.ready')\n worker=multiprocessing.get_context('spawn').Process(target=child,args=(str(ready),));worker.start()\n deadline=time.monotonic()+2\n while not ready.exists() and time.monotonic()<deadline:time.sleep(.01)\n assert ready.exists()\n owner=agent_run.process_owner(worker);real_kill=worker.kill\n def denied(*a,**kw):raise PermissionError(errno.EPERM,'forced refusal')\n worker.terminate=denied;worker.kill=denied\n try:\n  with patch.object(os,'killpg',side_effect=denied):receipt=api_run._stop_worker(worker,owner=owner)\n  assert worker in multiprocessing.active_children()\n  api_run._disable_unconfirmed_worker_join(worker,receipt)\n  assert worker not in multiprocessing.active_children()\n  started=time.monotonic();multiprocessing.util._exit_function();elapsed=time.monotonic()-started\n  assert elapsed<.2\n  assert receipt['status']=='incomplete' and receipt['automatic_exit_join']=='disabled'\n  print(json.dumps({'runtime_exit_seconds':elapsed,'cleanup':receipt}))\n finally:\n  real_kill();worker.join(timeout=2)\n")
        case=self.evidence/"runtime-exit-evidence";case.mkdir()
        proc=invoke([sys.executable,str(script)],timeout=5,evidence=case)
        self.assertEqual(proc.returncode,0,proc.stdout+proc.stderr)
        self.assertIn('"automatic_exit_join": "disabled"',proc.stdout)
    def test_real_sdk_short_timeout_startup_race_keeps_result_and_budget_hold(self):
        for index in range(3):
            case=self.evidence/("startup"+str(index));case.mkdir()
            args=[sys.executable,str(REPO/"Tools/agents/api_run.py"),"startup",str(self.task),"--model","fixture-model","--budget","2","--budget-config",str(self.config),"--ledger",str(case/"budget.json"),"--records-root",str(case/"records"),"--cwd",str(self.cwd),"--watch",".","--timeout","0.001"]
            env={"PYTHONPATH":str(Path(__file__).parent/"fixtures/mock_sdk"),"ANTHROPIC_API_KEY":"PUBLIC_SYNTHETIC_OFFLINE_CANARY_NOT_A_KEY","SDK_SCENARIO":"timeout"}
            proc=invoke(args,env=env,timeout=6,evidence=case)
            self.assertEqual(proc.returncode,124,proc.stdout+proc.stderr)
            run=next((case/"records").glob("*/result.json")).parent;result=json.loads((run/"result.json").read_text())
            self.assertEqual(result["runner_terminal_reason"],"wall_clock_timeout")
            self.assertTrue((run/"process-cleanup.json").exists());self.assertTrue((run/"snapshots/after/manifest.json").exists())
            self.assertIsNone(result["cost_usd"])
            row=next(iter(json.loads((case/"budget.json").read_text())["runs"].values()));self.assertEqual(row["status"],"unknown_cost_hold")

if __name__=="__main__":unittest.main(verbosity=2)
