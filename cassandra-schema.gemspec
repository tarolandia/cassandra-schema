# -*- encoding: utf-8 -*-

Gem::Specification.new do |s|
  s.name = "cassandra-schema"
  s.version = "0.2.0"
  s.summary = "Cassandra schema migrations"
  s.license = "MIT"
  s.description = "Simple reversible schema migrations for Cassandra."
  s.authors = ["Lautaro Orazi"]
  s.email = ["orazile@gmail.com"]
  s.homepage = "https://github.com/tarolandia/cassandra-schema"
  s.require_paths = ["lib"]

  s.files = `git ls-files`.split("\n")
end
