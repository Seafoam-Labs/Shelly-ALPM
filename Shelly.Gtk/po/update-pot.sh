#!/bin/bash

xgettext --no-location --keyword=T -o shelly-ui.pot --from-code=UTF-8 ../*.cs ../*/*.{cs,ui} ../*/*/*.{cs,ui} ../*/*/*/*.cs
