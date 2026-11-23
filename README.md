# sbiki

Cameraman Tower Defense auto farm (v11, lobby + match).

## Run (auto-load)

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/kbisnyu-cpu/sbiki/main/cmtd_auto.lua"))()
```

Auto-load is on: the script re-queues itself with `queue_on_teleport` and reloads from this repo after every teleport (lobby <-> match), so you only run the line above once.
Needs an executor that supports `queue_on_teleport` and `getgenv`.