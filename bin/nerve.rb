#!/usr/bin/ruby

Dir.chdir File.join(File.dirname(__FILE__), "..")
Process.exec("rackup -p 10100")
