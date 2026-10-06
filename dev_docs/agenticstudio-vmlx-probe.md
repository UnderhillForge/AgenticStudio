# AgenticStudio — probe vmlx

Paste this on the Mac Mini, workspace `/Volumes/NO NAME/AgenticStudio` or any terminal there. Do not change the plugin. This is a connectivity test only.

---

My local MLX server should be at http://localhost:8081 and is not replying. Find out why. Do not edit AgenticStudio scenes, jobs, or `user://agentic_studio.cfg`.

- `curl -sv --max-time 5 http://127.0.0.1:8081/` and the same for `http://localhost:8081/`. Record status, body, and whether the connection was refused, timed out, or reset.
- Probe the usual OpenAI-compatible paths on that port: `/v1/models`, `/v1/chat/completions` (GET is enough if POST is refused), `/health`. Note which path exists.
- Check what is actually listening: `lsof -nP -iTCP:8081 -sTCP:LISTEN` and `lsof -nP -iTCP -sTCP:LISTEN | rg -i 'mlx|ollama|vmlx|python|llama'`.
- If nothing is on 8081, look for a vmlx or mlx process and the port it printed. Check `brew services`, a launch agent, and a recent terminal running mlx-lm, mlx-serve, or vmlx.
- If the process is up but bound to another interface, say so. AgenticStudio must keep using 127.0.0.1, not a LAN address.

Report only: process or none, bind address, the one URL that returned a model list, and the exact error AgenticStudio would see if Plan called `{base}/chat/completions` with base `http://127.0.0.1:8081/v1`. Do not start a second server if one is already running. If none is running, give the single command that starts it on 8081 and stop there.
