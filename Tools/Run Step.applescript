-- Runs Reel/Tools/step.sh in the background and logs to step.log next to it.
set toolsDir to (POSIX path of (path to desktop folder)) & "Reel/Tools"
do shell script "cd " & quoted form of toolsDir & " && (nohup bash step.sh; echo \"STEP-EXIT=$?\") > step.log 2>&1 &"
return "Started Ñ progress in " & toolsDir & "/step.log"
