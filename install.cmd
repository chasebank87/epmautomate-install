:; curl -fsSL https://raw.githubusercontent.com/chasebank87/epmautomate-install/master/install.sh | sh; exit
@echo off
powershell -NoProfile -ExecutionPolicy Bypass -Command "iex (irm -useb 'https://raw.githubusercontent.com/chasebank87/epmautomate-install/master/install.ps1')"
