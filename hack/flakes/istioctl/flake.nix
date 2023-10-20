# Copyright 2023 D2iQ, Inc. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

{
  description = "Connect, secure, control, and observe services";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    utils.url = "github:numtide/flake-utils/v1.0.0";
  };

  outputs =
    { self
    , nixpkgs
    , utils
    ,
    }:
    let
      appReleaseVersion = "1.19.3";
      appReleaseBinaries = {
        "x86_64-linux" = {
          fileName = "istioctl-${appReleaseVersion}-linux-amd64.tar.gz";
          sha256 = "392ac51d42400d92eafdca631906a329d5d2caf319ce79c34a83e35ad7611a0e";
        };
        "x86_64-darwin" = {
          fileName = "istioctl-${appReleaseVersion}-osx-amd64.tar.gz";
          sha256 = "cad0cd7f936feffa2ee98654a2aaa9bdaeaf99b88509a83493ab7b9913eb9056";
        };
        "aarch64-darwin" = {
          fileName = "istioctl-${appReleaseVersion}-osx-arm64.tar.gz";
          sha256 = "83ac8d4ca14bc960b7f28c08655e7c37522653a153c6aeabb2128c4f553e5f2e";
        };
      };
      supportedSystems = builtins.attrNames appReleaseBinaries;
    in
    utils.lib.eachSystem supportedSystems (system:
    let
      pkgs = nixpkgs.legacyPackages.${system};
      appReleaseBinary = appReleaseBinaries.${system};
    in
    rec {
      packages.istioctl = pkgs.stdenv.mkDerivation {
        pname = "istioctl";
        version = appReleaseVersion;

        src = pkgs.fetchurl {
          url = "https://github.com/istio/istio/releases/download/${appReleaseVersion}/${appReleaseBinary.fileName}";
          sha256 = appReleaseBinary.sha256;
        };

        sourceRoot = ".";

        installPhase = ''
          install -m755 -D istioctl $out/bin/istioctl
        '';
      };
      packages.default = packages.istioctl;

      apps.istioctl = utils.lib.mkApp {
        drv = packages.istioctl;
      };
      apps.default = apps.istioctl;
    });
}
