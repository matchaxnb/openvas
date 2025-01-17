#!/bin/bash
#
BUILDHOME=$(pwd)
STARTTIME=$(date +%s)
NOBASE="false"
RUNAFTER="1"
ARM="false"
ARMSTART=true
PRUNESTART=true
BASESTART=true
PUBLISH=" "
RUNOPTIONS=" "
OS=$(uname)
echo "OS is $OS"
if [ "$OS" == "Darwin" ]; then
	STAT="-f %a"
else
	STAT="-c %s"
fi
echo "STAT is $STAT"
TimeMath() {
    local total_seconds="$1"
    local hours=$((total_seconds / 3600))
    local minutes=$(( (total_seconds % 3600) / 60 ))
    local seconds=$((total_seconds % 60))

    printf "%02d:%02d:%02d\n" "$hours" "$minutes" "$seconds"
}
PullArchives() {
	curl -L --url https://www.immauss.com/openvas/latest.base.sql.xz -o base.sql.xz && \
    curl -L --url https://www.immauss.com/openvas/latest.var-lib.tar.xz -o var-lib.tar.xz && \
    if [ $(ls -l /usr/lib/base.sql.xz | awk '{print $5}') -lt 1200 ]; then 
		echo "base.sql.xz size is invalid."
		exit 1
	fi 
    if [ $(ls -l /usr/lib/var-lib.tar.xz | awk '{print $5}') -lt 1200 ]; then 
		echo "var-lib.tar.xz size is invalid."
		exit 1
	fi
}

while ! [ -z "$1" ]; do
  case $1 in
    --push)
	shift
	PUBLISH="--push"
	;;
	-t)
	shift
	tag=$1
	shift	
	;;
	-a)
	shift
	arch=$1
	shift
	;;
	-p)
	echo " Flushing build kit cache"
	PRUNESTART=$(date +%s)
	docker buildx prune -af 
	PRUNEFIN=$(date +%s)
	shift
	;;
	-N)
	shift
	NOBASE=true;
	echo "Skipping ovasbase build"
	;;
	-n)
	shift
	RUNAFTER=0
	echo "OK, we'll skip running the image after build"
	;;
	*)
        echo "I don't know what to do with $1 option"
	echo "Sorry ...."
	exit
	;;

  esac
done
if [ -z  $tag ]; then
	tag=latest
fi
echo "TAG $tag"
if [ "$tag" == "beta" ]; then
	echo "tag set to beta. Only building x86_64. and using local volume"
	arch="linux/amd64"
	PUBLISH="--load"
	RUNOPTIONS="--volume beta:/data"
	NOBASE=true
elif [ -z $arch ]; then
	arch="linux/amd64,linux/arm64,linux/arm/v7"
	ARM="true"
fi
# Check to see if we need to pull the latest DB. 
# yes if it doesn't already exists
# Yes if the existing is < 7 days old.
echo "Checking Archive age"
if [ -f base.sql.xz ]; then
	DBAGE=$(expr $(date +%s) - $(stat $STAT var-lib.tar.xz) )
else
	PullArchives
fi
echo "Current archive age is: $DBAGE seconds"
if [ $DBAGE -gt 604800 ]; then
	PullArchives
fi
echo "Building with $tag and $arch"
set -Eeuo pipefail
if  [ "$NOBASE" == "false" ]; then
	cd $BUILDHOME/ovasbase
	BASESTART=$(date +%s)
	# Always build all archs for ovasbase.
	docker buildx build --push  --platform  linux/amd64,linux/arm64,linux/arm/v7 -f Dockerfile -t immauss/ovasbase  .
	BASEFIN=$(date +%s)
	cd ..
fi
cd $BUILDHOME
# Use this to set the version in the Dockerfile.
# This hould have worked with cmd line args, but does not .... :(
	DOCKERFILE=$(mktemp)
	sed "s/\$VER/$tag/" Dockerfile > $DOCKERFILE
# Because the arm64 build seems to always fail when building a the same time as the other archs ....
# We'll build it first to have it cached for the final build. But we only need the slim
#
if [ "$ARM" == "true" ]; then
	ARM64START=$(date +%s)
	docker buildx build --build-arg TAG=${tag}  \
	   --platform linux/arm64 -f Dockerfile --target slim -t immauss/openvas:${tag}-slim \
	   -f $DOCKERFILE .
	ARM64FIN=$(date +%s)
fi
# Now build everything together. At this point, this will normally only be the arm7 build as the amd64 was likely built and cached as beta.
SLIMSTART=$(date +%s)
docker buildx build --build-arg TAG=${tag} $PUBLISH \
   --platform $arch -f Dockerfile --target slim -t immauss/openvas:${tag}-slim \
   -f $DOCKERFILE .
SLIMFIN=$(date +%s)



FINALSTART=$(date +%s)
docker buildx build --build-arg TAG=${tag} $PUBLISH --platform $arch -f Dockerfile \
   --target final -t immauss/openvas:${tag} \
   -f $DOCKERFILE .
FINALFIN=$(date +%s)


#Clean up temp file
rm $DOCKERFILE


echo "Statistics:"
# First the dependent times
if ! [ $PRUNESTART ]; then
	PRUNE=$(expr $PRUNEFIN - $PRUNESTART)
	echo "Build Kit Cache flush: $(Timemath $PRUNE)" | tee timing
fi
if ! [ $BASESTART ]; then 
	BASE=$(expr $BASEFIN - $BASESTART )
	echo "ovasbase build time: $(TimeMath $BASE)" | tee -a timing
fi
if ! [ $ARMSTART ]; then
	ARM=$(expr $ARMFIN -$ARMSTART )
	echo "ARM64 Image build time: $(TimeMath $ARM)" | tee -a timing
fi
# These always run
SLIM=$(expr $SLIMFIN - $SLIMSTART )
FINAL=$(expr  $FINALFIN - $FINALSTART )
FULL=$(expr $FINALFIN - $STARTTIME )
echo "Slim Image build time: $(TimeMath $SLIM)" | tee -a timing
echo "Final Image build time: $(TimeMath $FINAL)" | tee -a timing
echo "Total run time: $(TimeMath $FULL)" | tee -a timing

if [ $RUNAFTER -eq 1 ]; then
	docker rm -f $tag
	# If the tag is beta, then we used --load locally, so no need to pull it. 
	if [ "$tag" != "beta" ]; then
		docker pull immauss/openvas:$tag
	fi
	docker run -d --name $tag -e SKIPSYNC=true -p 8080:9392 $RUNOPTIONS immauss/openvas:$tag 
	docker logs -f $tag
fi
