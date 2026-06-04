#!/bin/bash

package_name="shelly-notifications"
package_version=$(grep -Po '(?<=<Version>)[^<]+' ../Shelly-Notifications.csproj)

xgettext --package-name="$package_name" \
            --package-version="$package_version" \
            --from-code=UTF-8 \
            --keyword=T \
            --output="$package_name".pot \
            ../*.cs \
            ../*/*.cs

for f in *.po
do
    msgmerge --update "$f" "$package_name".pot
done
