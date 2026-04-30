@echo off

set /P comment=Comment?

if not "%comment%" == "" goto :next
set comment=auto
:next

git reset

::git add *.* --force
::git add *
git add --all

echo ----- git add done ------

git status

echo ready. press any key to commit START.
::timeout /t 1
pause

git commit -m "%comment%"

git push -u origin main

pause
