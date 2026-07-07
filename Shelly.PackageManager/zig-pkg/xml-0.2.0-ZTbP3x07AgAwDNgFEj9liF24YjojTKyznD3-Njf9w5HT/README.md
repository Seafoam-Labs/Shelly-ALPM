# zig-xml

zig-xml is an XML library for Zig, currently supporting Zig 0.15.0 and the
latest master at the time of writing.

See the documentation in the code for more information about the available APIs
(start in `xml.zig`). Autodocs are also published to GitHub Pages:
http://ianjohnson.dev/zig-xml/

The library aims to confirm with the following standards:

- [XML 1.0 Fifth Edition](https://www.w3.org/TR/2008/REC-xml-20081126/)
- [XML Namespaces 1.0 Third Edition](https://www.w3.org/TR/2009/REC-xml-names-20091208/)

Currently, DTDs (DOCTYPE) are not supported.

Other standards (such as XML 1.1 or XML 1.0 prior to the fifth edition) are only
supported insofar as they are compatible with the above standards.

## Examples

A basic example of usage can be found in the `examples` directory, and can be
built using `zig build install-examples`.

## Tests

The library has several tests of its own, which can be run using `zig build test`.

The `xmlconf` directory additionally contains a runner for the [W3C XML
Conformance Test Suite](https://www.w3.org/XML/Test/). Running `zig build test`
in that directory will fetch the test suite distribution tarball and run the
tests within. Due to features missing in the current parser implementation (DTD
support), many tests are currently skipped. At the time of writing, 250 tests
pass, and 924 are skipped due to unsupported features.

## Fuzzing

There is a fuzzing sub-project in the `fuzz` directory using
https://github.com/kristoff-it/zig-afl-kit.

Recommended fuzzing command:

```sh
afl-fuzz -x dictionaries/xml.dict -x dictionaries/xml_UTF_16.dict -x dictionaries/xml_UTF_16BE.dict -x dictionaries/xml_UTF_16LE.dict -i inputs -o outputs zig-out/bin/fuzz-xml
```

## License

zig-xml is free software, released under the [Zero Clause BSD
License](https://spdx.org/licenses/0BSD.html), as found in the `LICENSE` file of
this repository. This license places no restrictions on your use, modification,
or redistribution of the library: providing attribution is appreciated, but not
required.
