# Duo Tracker

A World of Warcraft: Forever addon for two people levelling characters in pairs. It shows which character in each pair has fallen behind on level and RestedXP guide step, and syncs both accounts over Battle.net whenever you are both online.

## Install or update

1. Download **Update Duo Tracker.bat** from this page (click the file, then the download button).
2. Double-click it. Windows may show "Windows protected your PC" the first time: click **More info**, then **Run anyway**.
3. Restart the game after the first install. After an update, type `/reload` in chat.

Running it once also switches on automatic updates: your PC then checks for a new version every 30 minutes in the background. When the addon says an update is available, open `/duo` and click the orange button to reload.

To switch automatic updates off, download and run **Remove Duo Tracker auto-update.bat**.

## In game

- `/duo` opens the window with every pair.
- When your partner's paired character is in your party, a quest you pick up is shared with them, and a quest they share with you is accepted for you. `/duo share` turns this off or back on. `/duo sync` shows the last quest shared or accepted.
- `/duo help` lists the other commands.

## If sync looks wrong

Type `/duo sync`. It lists whether your partner was found, when the last message from them arrived, which version they run, and anything that was thrown away and why. The top of the `/duo` window shows the same in short.

## For developers

`python tools/test.py` runs the offline tests: two copies of the addon syncing with each other on a fake game, including against the older 1.6.1 and 1.7.0 code. Install the one dependency with `pip install -r tools/requirements.txt`, and switch on the commit check once with `git config core.hooksPath .githooks`.
