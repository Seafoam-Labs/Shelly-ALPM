#!/bin/bash

package_name="shelly-ui"
package_version=$(grep -Po '(?<=<Version>)[^<]+' ../Shelly.Gtk.csproj)

xgettext --package-name="$package_name" \
            --package-version="$package_version" \
            --from-code=UTF-8 \
            --keyword=T \
            --no-location \
            --output="$package_name"_new.pot \
            ../*.cs \
            ../*/{*.cs,*.ui} \
            ../*/*/{*.cs,*.ui}

msgcat --no-location \
        --use-first \
        "$package_name".pot \
        "$package_name"_new.pot \
        -o "$package_name"_tmp.pot

mv "$package_name"_tmp.pot shelly-ui.pot
rm "$package_name"_new.pot
