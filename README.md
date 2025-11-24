# Survival.as

## Information
A simple and configurable plugin to add survival to Sven Co-op maps that don't normally support survival mode
On maps that do support vanilla survival mode, this plugin will fully disable for that map and just use vanilla survival.
This survival mode also allows late joiners to still spawn in, instead of having to wait for the next map (rejoining after dying won't work though).

## Installation 
Works with the v5.26 Build of Sven Co-Op.    

Download Link of the Last Stable version of Plugin
Installation Instructions
Copy 'Survival.as' to 'svencoop\scripts\plugins'. And add this to 'default_plugins.txt':

```
    "plugin"
    {
        "name" "Survival"
        "script" "Survival"
        "concommandns" "survival"
    }
```

Add this to 'server.cfg'

```
// Survival Mode Plugin
as_command survival.enabled 1
as_command survival.lateSpawn 1
```
  
## Configs:
There are multiple configurations you can manipulate, you have to go to console and type `as_command survival.cvar value`.
Add the below defaults to your "server.cfg" file if you haven't already.

You can use a .cfg file to give a map unique settings for the plugin.
Just navigate to the folder of the map, and find/create a file named mapname.cfg and put lines with `as_command survival.cvar value`

Adjust values above as needed. If a .cfg file is not found for the map, then it will assume the values you put in server.cfg

## CVar Help:
```
enabled - (1 (True) or 0 (False)) Fully enable/disable the plugin
lateSpawn - (1 (True) or 0 (False))  Whether to allow late joiners to still spawn in
```

## Support

[Support discord here!]( https://discord.gg/3tP3Tqu983)

## License

[CC0](https://creativecommons.org/public-domain/cc0/)
