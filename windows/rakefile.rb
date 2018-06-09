# Expects the Cygwin/MSYS environment

require 'digest'

module RT
  Version = '2.5.1-1'
  Archive = "rubyinstaller-#{Version}-x86.7z"
  URL = "https://github.com/oneclick/rubyinstaller2/releases/download/rubyinstaller-#{Version}/#{Archive}"
end

Dist = 'dist'
Bin = File.join(Dist, 'bin')

file RT::Archive do
    sh "wget #{RT::URL}"
end

directory Dist
directory Bin

task :clobber do
  rm_rf Dist
end

task :extract_rt => [Dist, RT::Archive] do
  chdir Dist do
    rm_rf 'ruby'
    sh "7z x -y ../#{RT::Archive}"
    sh 'mv rubyinstaller* ruby'
  end
end

task :trim_rt => :extract_rt do
  chdir File.join(Dist, 'ruby') do
    sh 'rm -rf include share/doc lib/{pkgconfig,*.a} lib/ruby/gems/*/{cache,doc}/*'
  end
end

task :install_gem do
  chdir "#{Dist}/ruby/bin" do
    sh "cmd /c gem.cmd install ../../../*gem"
  end
end

task :build_launcher => Bin do
  sh "gcc -s -O2 -DNDEBUG -o #{Bin}/rockup.exe rockup.c"
end

task :build => [:install_gem, :build_launcher, :trim_rt] do
  pf = ENV['ProgramFiles(x86)']
  sh %{"#{pf}/Inno Setup 5/iscc.exe" rockup.iss}
end

task :default => :build