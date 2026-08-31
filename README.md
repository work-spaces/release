# release

This repo is used to test and release `spaces`.

```sh
export SPACES_TAG=v0.21.2
export PREVIOUS_SPACES_TAG=v0.21.0
export SDK_TAG=v0.5.1
export PACKAGES_TAG=v0.2.72
spaces checkout-repo \
    --url=https://github.com/work-spaces/release \
    --rev=main \
    --name=release-$SPACES_TAG \
    --store=RELEASE_SPACES_TAG=$SPACES_TAG \
    --store=RELEASE_PREVIOUS_SPACES_TAG=$PREVIOUS_SPACES_TAG \
    --store=RELEASE_SDK_TAG=$SDK_TAG \
    --store=RELEASE_PACKAGES_TAG=$PACKAGES_TAG
```
