#!/bin/sh
# Haiku Maincraft Installer based on https://github.com/alexivkin/minecraft-launcher

VERSION="1.3.1"

# Check x86_64 arch
arch=$(getarch)
if [[ $arch != "x86_64" ]]; then
	alert --stop "This Minecraft Installer only for Haiku x86_64 architecture."
	exit
fi

# Defs
JAVA="/system/lib/openjdk17/bin/java"
TESTED_VERSIONS_LIST="1.13.2 1.14.4 1.15.2 1.16.5 1.17.1 1.18.2 1.19.4"
MAINLINE_VERSIONS_JSON=https://launchermeta.mojang.com/mc/game/version_manifest.json
LWJGL_HAIKU_URI=https://haikuware.ru/files/lwjgl3/lwjgl-3.3.2-haiku-minimal-x64.zip
EULA_URI="https://minecraft.net/en-us/eula"
USER_UUID=0
ACCESS_TOKEN=0

# Timeouts
NOTIFY_ICON=$0
NOTIFY_TIMEOUT=120
NOTIFY_MSG_ID=$RANDOM
CURL_RETRY="--connect-timeout 20 --retry 20 --retry-delay 1 --retry-max-time 45"

# Functions
function ShowNotify {
	notify --icon "$NOTIFY_ICON" --type information --group "Minecraft installer" \
		--messageID $NOTIFY_MSG_ID --timeout $NOTIFY_TIMEOUT "$1"
}

function ShowProgress {
	notify --icon "$NOTIFY_ICON" --type progress --group "Minecraft installer" \
		--messageID $NOTIFY_MSG_ID --timeout $NOTIFY_TIMEOUT --progress "$1" "$2"
}

function VersionSelector {
	index=0
	list=($2)
	count=${#list[*]}	
	while true
	do
		alert --idea "$1" "⇦" "${list[$index]}" "⇨" >/dev/null
		case "$?" in
		"0" )
			if [ "$index" -gt "0" ]; then
				index=$(( $index - 1))
			fi
			;;
		"2" )
			if [ "$index" -lt "$(( $count - 1 ))" ]; then
				index=$(( $index + 1))
			fi
			;;
		"1" )
			echo ${list[$index]}
			break
			;;
		esac
	done
}

# Make application dir
TARGET_DIR="`finddir B_USER_NONPACKAGED_DIRECTORY`/apps/Minecraft"
mkdir -p $TARGET_DIR
cd $TARGET_DIR

# Menu
action=`alert --idea "Simple Minecraft Installer $VERSION" "Install" "EULA" "Cancel"`
if [[ $action == "Cancel" ]]; then
	exit
fi

if [[ $action == "EULA" ]]; then
	open "$EULA_URI"
	exit
fi

# Select version
MAINLINE_VERSION=`VersionSelector "Select Minecraft version for install" "$TESTED_VERSIONS_LIST"`
MAINLINE_VERSION_MAJOR="`echo "$MAINLINE_VERSION" | cut -d. -f1`"
MAINLINE_VERSION_MIDDLE="`echo "$MAINLINE_VERSION" | cut -d. -f2`"
MAINLINE_CLIENT_JAR="versions/$MAINLINE_VERSION/$MAINLINE_VERSION.jar"

# Install dependencies
ShowProgress 0 "Installing dependencies"
pkgman install cmd:bc -y

pkg_count=4
pkg_idx=0
for package in cmd:jq openjdk17_jre glfw openal
do
	pkg_progress=`echo "scale=2;$pkg_idx/$pkg_count" | bc`
	ShowProgress $pkg_progress "Installing dependencies"
	pkgman install $package -y
	pkg_idx=`echo "$pkg_idx+1" | bc`
done

# Get json version
VERSION_JSON=$(curl $CURL_RETRY -s $MAINLINE_VERSIONS_JSON | jq --arg VERSION "$MAINLINE_VERSION" -r '[.versions[]|select(.id == $VERSION)][0].url')
VERSION_DETAILS=$(curl $CURL_RETRY -s $VERSION_JSON)

# Make dir for minecraft version
mkdir -p versions/$MAINLINE_VERSION

# Get client jar
ShowProgress 0.0 "Getting the game files from Mojang..."
curl $CURL_RETRY -sSL -o $MAINLINE_CLIENT_JAR $(echo $VERSION_DETAILS | jq -r '.downloads.client.url')

# Get asset index
ASSET_INDEX=$(echo $VERSION_DETAILS | jq -r '.assetIndex.id')
if [[ ! $ASSET_INDEX == "null" ]]; then
    ASSET_INDEX_FILE="assets/indexes/$ASSET_INDEX.json"
    if [[ ! -f $ASSET_INDEX_FILE ]]; then
		ShowProgress 0.5 "Getting the game files from Mojang..."
        mkdir -p assets/indexes
        curl $CURL_RETRY -sSL -o $ASSET_INDEX_FILE $(echo $VERSION_DETAILS | jq -r '.assetIndex.url')
    fi
fi

# Get log file
LOG_FILE=$(echo $VERSION_DETAILS | jq -r '.logging.client.file.id')
if [[ ! $LOG_FILE == "null" ]]; then
    LOG_CONFIG="logging-$LOG_FILE"
    if [[ ! -f $LOG_CONFIG ]]; then
		ShowProgress 0.75 "Getting the game files from Mojang..."
        curl $CURL_RETRY -sSL -o "versions/$MAINLINE_VERSION/$LOG_CONFIG" $(echo $VERSION_DETAILS | jq -r '.logging.client.file.url')
    fi
fi
ShowProgress 1.0 "Getting the game files from Mojang..."

# Get libs
lib_base="versions/$MAINLINE_VERSION/libraries"
lib_count=$(echo $VERSION_DETAILS | jq -rc '.libraries[]' | wc -l)
lib_idx=0
for lib in $(echo $VERSION_DETAILS | jq -rc '.libraries[]'); do
    lib_name="$lib_base/$(echo $lib | jq -r '.downloads.artifact.path')"
    lib_path=$(dirname $lib_name)
    lib_url=$(echo $lib | jq -r '.downloads.artifact.url')
    lib_sha1=$(echo $lib | jq -r '.downloads.artifact.sha1')
    lib_progress=`echo "scale=2;$lib_idx/$lib_count" | bc`
    if [[ ! $lib_name == "$lib_base/null" && ! -f $lib_name ]]; then
        allowed="allow"
        rules=$(echo $lib | jq -rc '.rules')
        if [[ ! $rules == "null" ]]; then
            allowed="disallow"
            for rule in $(echo $lib | jq -rc '.rules[]'); do
                if [[ $(echo $rule | jq -r '.os.name') == "null" || $(echo $rule | jq -r '.os.name') == "linux" ]]; then
                    allowed=$(echo $rule | jq -r '.action')
                fi
            done
            if [[ $allowed == "disallow" ]]; then
                continue
            fi
        fi
        ShowProgress $lib_progress "Getting the library files from Mojang..."
        mkdir -p $lib_path
        curl $CURL_RETRY -sSL -o $lib_name $lib_url
        if [[ ! -z $lib_sha1 ]]; then
            if echo "$lib_sha1 $lib_name" | sha1sum --quiet -c -; then
                :
            else
                ShowNotify "$lib_name checksum is wrong. Remove and re-run."
                exit 1
            fi
        fi
    fi
    lib_idx=`echo "$lib_idx+1" | bc`
done

# Replace LWJGL
rm -rf $lib_base/org/lwjgl/*
ShowProgress 0.0 "Downloading $(basename $LWJGL_HAIKU_URI)"
curl $CURL_RETRY -sSL -o $lib_base/$(basename $LWJGL_HAIKU_URI) $LWJGL_HAIKU_URI
ShowProgress 0.5 "Downloading $(basename $LWJGL_HAIKU_URI)"
unzip $lib_base/$(basename $LWJGL_HAIKU_URI) -d $lib_base/org/lwjgl
ShowProgress 1.0 "Downloading $(basename $LWJGL_HAIKU_URI)"
rm $lib_base/$(basename $LWJGL_HAIKU_URI)

# Make dir for native libs
native_lib_dir="versions/$MAINLINE_VERSION/natives"
mkdir -p $native_lib_dir

# Get asset objects
OBJ_SERVER="https://resources.download.minecraft.net"
OBJ_FOLDER="assets/objects"
obj_count=$(cat $ASSET_INDEX_FILE | jq -rc '.objects[] | .hash' | wc -l)
obj_idx=0
for objhash in $(cat $ASSET_INDEX_FILE | jq -rc '.objects[] | .hash'); do
    id=${objhash:0:2}
    objfile=$OBJ_FOLDER/$id/$objhash
    progress=`echo "scale=2;$obj_idx/$obj_count" | bc`    
    if [[ ! -f $objfile ]]; then
		ShowProgress $progress "Getting the assets files from Mojang..."
        mkdir -p "$OBJ_FOLDER/$id"
        curl $CURL_RETRY -sSL -o $objfile $OBJ_SERVER/$id/$objhash
    else
    	ShowProgress $progress "Getting the assets files from Mojang... Skip"
    fi
    obj_idx=`echo "$obj_idx+1" | bc`
done

# Rebuild the class path
CP=""
pushd $lib_base
for lib in $(find * -name '*.jar'); do
	CP="${CP}libraries/$lib:"
done
popd
CP="${CP}$(basename $MAINLINE_CLIENT_JAR)"

# Build minecraft args from arglist if minecraftArguments string is absent
GAME_ARGS=$(echo $VERSION_DETAILS | jq -r '.minecraftArguments')
if [[ $GAME_ARGS == "null" ]]; then
    GAME_ARGS=$(echo $VERSION_DETAILS | jq -r  '[.arguments.game[] | strings] | join(" ")')
fi

# Launcher script
START_FILE="Minecraft-$MAINLINE_VERSION"
ShowNotify "Creating launcher script"

cat > $START_FILE << EOF
#!/bin/bash
scriptdir="\$(dirname "\$(readlink -f "\${BASH_SOURCE[0]}")")"
cd "\${scriptdir}/versions/$MAINLINE_VERSION" || exit 1

gamedir="`finddir B_USER_SETTINGS_DIRECTORY`/minecraft/$MAINLINE_VERSION"
mkdir -p \$gamedir

$JAVA \\
	-Xmx2048M \\
	-Xss1M \\
	-XX:+UnlockExperimentalVMOptions \\
	-XX:+UseG1GC \\
	-XX:G1NewSizePercent=20 \\
	-XX:G1ReservePercent=20 \\
	-XX:MaxGCPauseMillis=50 \\
	-XX:G1HeapRegionSize=32M \\
	-Dlog4j2.formatMsgNoLookups=true \\
	-Dlog4j.configurationFile=logging-client-1.12.xml \\
	-Djava.library.path=natives \\
	-cp "$CP" \\
	net.minecraft.client.main.Main \\
	--version $MAINLINE_VERSION \\
	--versionType release \\
	--gameDir \$gamedir \\
	--assetsDir ../../assets \\
	--assetIndex $ASSET_INDEX \\
	--username Name \\
	--uuid $USER_UUID \\
	--accessToken $ACCESS_TOKEN \\
	--userType mojang
EOF

chmod +x $START_FILE
copyattr -n BEOS:ICON "$0" "$START_FILE"

# Install to Deskbar menu
APP_MENU_DIR="`finddir B_USER_SETTINGS_DIRECTORY`/deskbar/menu/Applications"
ln -s -f "$TARGET_DIR/$START_FILE" "$APP_MENU_DIR/$START_FILE"

ShowNotify "Minecraft $MAINLINE_VERSION installed"

# Done
action=`alert --idea "Minecraft $MAINLINE_VERSION installed." "Open folder" "Close" "Run"`
if [[ $action == "Run" ]]; then
	exec "$TARGET_DIR/$START_FILE"
	exit
fi
if [[ $action == "Open folder" ]]; then
	open "$TARGET_DIR"
	exit
fi
