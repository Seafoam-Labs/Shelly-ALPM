#!/bin/bash

cd Shelly.Gtk/po/

find .. -type f \( -name "*.cs" -or -name "*.ui" \) | \
    xgettext --no-location --keyword=T -o shelly-ui.pot \
            --from-code=UTF-8 -f -

for f in *.po
do
    msgmerge --no-location --update --backup=none "$f" shelly-ui.pot
done

cd -
cd Shelly-Notifications/po/

find .. -type f \( -name "*.cs" -or -name "*.ui" \) | \
    xgettext --no-location --keyword=T -o shelly-notifications.pot \
            --from-code=UTF-8 -f -

for f in *.po
do
    msgmerge --no-location --update --backup=none "$f" shelly-notifications.pot
done

cd -
