#!/usr/bin/env python3
import json,os,signal,subprocess,sys,time
from pathlib import Path
args=sys.argv[1:]
name=next((x for x in ("rev-parse","status","diff","ls-files") if x in args),"unknown")
if name=="diff" and "--cached" in args:name="staged"
mode=os.environ.get("MOCK_GIT_MODE","success")
print("NORMAL_STDOUT_"+name,flush=True)
print("NORMAL_STDERR_"+name,file=sys.stderr,flush=True)
if mode=="error":sys.exit(23)
if mode=="hang" or mode=="hang-status" and name=="status":
 signal.signal(signal.SIGTERM,signal.SIG_IGN)
 child=subprocess.Popen([sys.executable,"-c","import signal,time; signal.signal(signal.SIGTERM,signal.SIG_IGN); print('CHILD_PARTIAL_OUTPUT',flush=True); time.sleep(3600)"])
 pid_dir=Path(os.environ["MOCK_GIT_PID_DIR"]);pid_dir.mkdir(parents=True,exist_ok=True)
 (pid_dir/(name+".json")).write_text(json.dumps({"leader":os.getpid(),"child":child.pid,"group":os.getpgrp()}))
 time.sleep(3600)
sys.exit(0)
