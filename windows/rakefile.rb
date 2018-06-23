require 'rake/clean'


raise '32-bit MinGW environment is required' unless ENV['MSYSTEM_CARCH'] == 'i686'


Root = Dir.pwd
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
  Version = '0.1.0'
  Build = 1
  Gem = "rockup-#{Version}.gem"
  Script = "#{Ruby::Dir}/bin/rockup"
  Dist = "rockup-#{Version}-#{Build}"
  DistExe = "#{Dist}.exe"
  LauncherExe = "#{Bin}/rockup.exe"
  LauncherSrc = "#{Root}/rockup.c"
end


module InnoSetup
  Script = 'rockup.iss'
  def self.iscc_exe
    reg32 = ENV['PROCESSOR_ARCHITECTURE'] == 'AMD64' ? '/reg:32' : nil
    cmd = %(reg query "HKEY_LOCAL_MACHINE\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\Inno Setup 5_is1" #{reg32})
    raise 'Inno Setup is not found' if (/InstallLocation\s*REG_SZ\s*(.*)$/ =~ `#{cmd}`).nil?
    "#{$1.strip}\\iscc.exe"
  end
  def self.def(k, v)
    %("/D#{k}=#{v}")
  end
end


def quote(s) %("#{s}") end


def build_cmd(file, *args)
  open(file, 'wt') do |out|
    out << args.join(' ')
  end
end

# Run through cmd.exe with intermediate .cmd file
def cmd(*args)
  begin
    open(batch = "#{Time.now.to_i}.cmd", 'wt') { |out| out << args.join(' ') }
    sh('cmd.exe', '/c', batch)
  ensure
    rm_rf batch
  end
end

[Bin, Dist].each {|x| directory x}


file Rockup::LauncherExe => [Rockup::LauncherSrc, Bin] do |t|
  sh "gcc -s -O2 -DNDEBUG -o #{t.name} #{t.prerequisites.first}"
end


file Ruby::Tarball do
  sh "wget #{Ruby::URL}"
end


file Ruby::Dir => [Ruby::Tarball, Dist] do
  sh "7z x -y #{Ruby::Tarball}"
  rm_rf Ruby::Dir
  mv Dir['rubyinstaller*'].first, Ruby::Dir
  touch Ruby::Dir # Since `mv` does not alter mtime
  chdir Ruby::Dir do
    sh "rm -rf bin/rockup.bat include share/doc lib/{pkgconfig,*.a} lib/ruby/gems/*/{cache,doc}/*"
  end
end


file Rockup::Script => ["../#{Rockup::Gem}", Ruby::Dir] do |t|
  sh "#{Ruby::Gem} install --local #{t.prerequisites.first}"
end


file Rockup::DistExe => [Rockup::LauncherExe, Ruby::Dir, Rockup::Script] do |t|
  cmd quote(InnoSetup.iscc_exe),
    InnoSetup.def(:MyOutput, Rockup::Dist), InnoSetup.def(:MyVersion, Rockup::Version), InnoSetup.def(:MyBuild, Rockup::Build),
    InnoSetup::Script
end


CLEAN.include Dist
CLOBBER.include Rockup::DistExe


task :default => Rockup::DistExe