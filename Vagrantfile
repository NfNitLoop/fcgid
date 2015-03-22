Vagrant.configure(2) do |config|
  config.vm.box = "ubuntu/trusty64"

  config.vm.box_check_update = false

  config.vm.network "forwarded_port", guest: 80, host: 8080
  config.vm.network "private_network", ip: "10.10.10.1"

  config.vm.provider "virtualbox" do |vb|
     vb.memory = "1024"
  end


  config.vm.provision "shell", inline: <<-SHELL
    # See: http://d-apt.sourceforge.net/
    sudo wget http://master.dl.sourceforge.net/project/d-apt/files/d-apt.list -O /etc/apt/sources.list.d/d-apt.list
    sudo apt-get update
    sudo apt-get -y --allow-unauthenticated install --reinstall d-apt-keyring
    sudo apt-get update
    sudo apt-get install -y dmd-bin dub apache2 libapache2-mod-fcgid
  SHELL
end
