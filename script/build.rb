#!/usr/bin/env ruby
# frozen_string_literal: true

# Builds smstunnel.szpm from src/. The result has no build date or host, so the same sources always
# give the same bytes. `ruby script/build.rb --check` fails if the committed package is out of date.

require 'base64'
require 'json'

ROOT    = File.expand_path('..', __dir__)
SOURCES = File.join(ROOT, 'src')
OUTPUT  = File.join(ROOT, 'smstunnel.szpm')
VERSION = '1.0.0'

def files
  Dir.glob('**/*', base: SOURCES).select { |path| File.file?(File.join(SOURCES, path)) }.sort.map do |path|
    {
      'location'   => path,
      'permission' => 644,
      'encode'     => 'base64',
      'content'    => Base64.strict_encode64(File.binread(File.join(SOURCES, path))),
    }
  end
end

package = {
  'name'        => 'SMSTunnel',
  'version'     => VERSION,
  'vendor'      => 'NARBOWEB SRL',
  'license'     => 'MIT',
  'url'         => 'https://github.com/narcisbodea/smstunnel-zammad',
  'change_log'  => [{ 'version' => VERSION, 'date' => '2026-11-21', 'log' => 'SMS account and SMS notification provider.' }],
  'description' => [{ 'language' => 'en', 'text' => 'SMS channel that sends and receives texts through your own Android phone with SMSTunnel.' }],
  'files'       => files,
}

built = "#{JSON.pretty_generate(package)}\n"

if ARGV.include?('--check')
  current = File.exist?(OUTPUT) ? File.binread(OUTPUT) : ''
  abort 'smstunnel.szpm is out of date: run ruby script/build.rb' if current != built
  puts 'smstunnel.szpm is up to date'
else
  File.binwrite(OUTPUT, built)
  puts "smstunnel.szpm #{VERSION}: #{package['files'].size} files"
end
