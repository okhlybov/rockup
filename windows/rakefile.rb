Dist = 'dist'
Bin = "#{Dist}/bin"


module Ruby
  Version = '2.5.1-1'
  Tarball = "rubyinstaller-#{Version}-x86.7z"
  URL = "https://github.com/oneclick/rubyinstaller2/releases/download/rubyinstaller-#{Version}/#{Tarball}"
  Dir = "#{Dist}/ruby"
end


module Rockup
  Gem = 'rockup-0.1.0.gem'
  Script = "#{Ruby::Dir}/bin/rockup"
end


module Launcher
  Exe = "#{Bin}/rockup.exe"
  Src = "#{Dir.pwd}/rockup.c"
end


[Bin, Dist].each {|x| directory x}

file Launcher::Exe => [Launcher::Src, Bin] do |t|
  sh "gcc -s -O2 -DNDEBUG -o #{t.name} #{t.prerequisites.first}"
end


file Ruby::Tarball do
  sh "wget #{Ruby::URL}"
end


file Ruby::Dir => [Ruby::Tarball, Dist] do
  sh "7z x -y #{Ruby::Tarball}"
  rm_rf Ruby::Dir
  mv Dir['rubyinstaller*'].first, Ruby::Dir
end


file Rockup::Script => ["../#{Rockup::Gem}", Ruby::Dir] do |t|
  sh "#{Ruby::Dir}/bin/gem.cmd install --local #{t.prerequisites.first}"
end


task :default => [Launcher::Exe, Ruby::Dir, Rockup::Script]