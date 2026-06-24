#!/bin/bash

find .. -type f \( -name "*.cs" -or -name "*.ui" \) | \
    xgettext --no-location --keyword=T -o shelly-ui.pot \
            --from-code=UTF-8 -f -

for f in *.po
do
    msgmerge --update --backup=none "$f" shelly-ui.pot
done
