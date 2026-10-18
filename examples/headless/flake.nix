# A headless Pi: wired networking and SSH, nothing else. Lock it, build it,
# flash it:
#
#   nix run github:danielbodart/nix-raspios-imagebuilder#lock -- .#pi raspios.lock.json
#   nix build .#raspiosImages.pi
#   nix run github:danielbodart/nix-raspios-imagebuilder#flash -- .#pi /dev/sdX
{
  inputs.raspios.url = "github:danielbodart/nix-raspios-imagebuilder";

  outputs = { raspios, ... }: {
    raspiosImages.pi = raspios.lib.mkImage {
      modules = with raspios.raspiosModules; [
        network
        ssh
        {
          name = "pi";
          lock = ./raspios.lock.json;
          ssh.authorizedKeys = [ "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExampleExampleExampleExampleExampleExample you@laptop" ];
        }
      ];
    };
  };
}
