# Expects the Cygwin/MSYS environment

require 'digest'

module RT
  Version = '2.5.1-1'
  Archive = "rubyinstaller-#{Version}-x86.7z"
  URL = "https://github.com/oneclick/rubyinstaller2/releases/download/rubyinstaller-#{Version}/#{Archive}"
end

Dist = 'dist'

file RT::Archive do
    sh "wget #{RT::URL}"
end

directory Dist

task :clobber do |t|
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

task :default => :extract_rt