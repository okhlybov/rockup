raise '32-bit MIinGW environment is required' unless ENV['MSYSTEM_CARCH'] == 'i686'


Dist = 'dist'
Bin = "#{Dist}/bin"


module Ruby
  Version = '2.5.1-1'
  Tarball = "rubyinstaller-#{Version}-x86.7z"
  URL = "https://github.com/oneclick/rubyinstaller2/releases/download/rubyinstaller-#{Version}/#{Tarball}"
  Dir = "#{Dist}/ruby"
  Gem = "#{Dir}/bin/gem.cmd"
  Ruby = "#{Dir}/bin/ruby.exe"
end


module Rockup
  Gem = 'rockup-0.1.0.gem'
  Script = "#{Ruby::Dir}/bin/rockup"
end


module Launcher
  Exe = "#{Bin}/rockup.exe"
  Src = "#{Dir.pwd}/rockup.c"
end


module InnoSetup
  def self.iscc_exe
    reg32 = ENV['PROCESSOR_ARCHITECTURE'] == 'AMD64' ? '/reg:32' : nil
    cmd = %(reg query "HKEY_LOCAL_MACHINE\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\Inno Setup 5_is1" #{reg32})
    raise 'Inno Setup is not found' if (/InstallLocation.*REG_SZ\s*(.*)$/ =~ `#{cmd}`).nil?
    "#{$1.strip}\\iscc.exe"
  end
end


CMD = ENV['COMSPEC']

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
  sh "#{Ruby::Gem} install --local #{t.prerequisites.first}"
end


task :default => [Launcher::Exe, Ruby::Dir, Rockup::Script]
