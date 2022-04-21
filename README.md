# dbrrg - Docker based RamRoot Generator

Generate boot images for diskless clients running entirely
from RAM.

The generated Images can be booted over the network as well as from an USB stick.

This requires docker to be present on your system.

## Usage

Run

```
make image
```

Now you find all the generated image files in the `image-export`.

## Todo

* Integrate the booserver system
* Modularize for alternate setups
* Add classic MBR variant of the image

## Licence

dbrrg is released under the MIT licence.

## Thanks

This setup is heavily inspired by https://github.com/medallia/ramroot and https://github.com/iximiuz/docker-to-linux