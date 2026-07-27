# Fixture for the completion tests: a module that adds a custom package
# declarator the way Red adds `model` — through the compile-time EXPORTHOW hook
# rather than a slang. Also exports an ordinary routine and a type, so the
# export-stash path is covered too.
#
# NOTE: EXPORTHOW has to sit at compunit scope. Wrapping this file in
# `unit module DeclFixture;` would silently stop `widget` from being a
# declarator at all.

class MetamodelX::Fixture::Widget is Metamodel::ClassHOW {}

my package EXPORTHOW {
    package DECLARE {
        constant widget = MetamodelX::Fixture::Widget;
    }
}

sub fixture-helper() is export { 42 }

class FixtureType is export { }

# Types for the typed-topic tests: `config -> Outer $_ { .aaa = 1 }`.
class Inner is export {
    has Int $.bbb;
}

class Outer is export {
    has Int   $.aaa;
    has Inner $.inner;
    has Int   $.ccc;
}
