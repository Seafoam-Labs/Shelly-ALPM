#!/bin/bash

package_name="shelly-ui"
package_version=$(grep -Po '(?<=<Version>)[^<]+' ../Shelly.Gtk.csproj)

xgettext --package-name="$package_name" \
            --package-version="$package_version" \
            --from-code=UTF-8 \
            --keyword=T \
            --output="$package_name".pot \
            ../*.cs \
            ../*/{*.cs,*.ui} \
            ../*/*/{*.cs,*.ui}

for f in *.po
do
    msgmerge --update "$f" "$package_name".pot
done
