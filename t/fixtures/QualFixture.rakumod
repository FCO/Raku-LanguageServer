# Packages are routinely declared fully qualified while references put the
# cursor on one segment — the shape that made `gd` fail on real projects.
role Deep::Nested::Thing {
    has $.value;
}

# Consumers of the role, for the implementation tests. The doc comment below is
# deliberate: prose mentioning `class ... does` used to swallow the real
# declaration that followed it.
#| This class itself does something with Deep::Nested::Thing.
class FirstConsumer does Deep::Nested::Thing { }
class SecondConsumer does Deep::Nested::Thing { }
