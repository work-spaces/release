# release

This repo is used to test and release `spaces`.

```sh
export SPACES_TAG=v0.20.6
export PREVIOUS_SPACES_TAG=v0.20.3
export SDK_TAG=v0.4.0
export PACKAGES_TAG=v0.2.67
spaces checkout-repo \
    --url=https://github.com/work-spaces/release \
    --rev=main \
    --name=release-$SPACES_TAG \
    --store=RELEASE_SPACES_TAG=$SPACES_TAG \
    --store=RELEASE_PREVIOUS_SPACES_TAG=$PREVIOUS_SPACES_TAG \
    --store=RELEASE_SDK_TAG=$SDK_TAG \
    --store=RELEASE_PACKAGES_TAG=$PACKAGES_TAG
```
