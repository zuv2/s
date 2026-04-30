@echo off

git fetch --all
git reset --hard origin/main
git pull
git repack -a -d --depth=250 --window=250
cd .git
rmdir /S /Q lfs
cd ..

pause