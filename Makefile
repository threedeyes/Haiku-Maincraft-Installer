build:
	cp installer.sh "Minecraft Installer"

	chmod +x "Minecraft Installer"
	settype -t application/x-vnd.Be-elfexecutable "Minecraft Installer"

	rc installer.rdef
	resattr -o "Minecraft Installer" installer.rsrc
	mimeset -f "Minecraft Installer"

clean:
	rm -f "Minecraft Installer" installer.rsrc
