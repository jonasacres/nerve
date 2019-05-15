require 'colorize'
require 'rest-client'
require 'sqlite3'
require 'json'
require 'open3'

manual = ['database_interface']

manual.each do |entry|
  require File.join(File.dirname(__FILE__), entry)
end

Dir.glob(File.join(File.dirname(__FILE__), "**/*.rb")).each do |script|
  require script
end
