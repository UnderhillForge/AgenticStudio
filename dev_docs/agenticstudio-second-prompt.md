# AgenticStudio — second prompt

Paste this into the coding agent with the workspace set to `/Volumes/NO NAME/AgenticStudio`. Phase 0 and Phase 1 are verified on Godot 4.7.beta1 arm64. A test model already answers an OpenAI-compatible `/v1/chat/completions`. Do not redo the dock or the settings dialog.

---

AgenticStudio Phase 0 and Phase 1 are in place: dock, model picker, Plan / Run / Auto-approve, settings in `user://agentic_studio.cfg`, job tabs under `user://agentic_studio/jobs/`. Plan currently writes a stub line and does not call a model. Scene edits do not exist yet. Leave them that way.

Wire Plan to the selected model. Do not edit scenes. Do not add pages, mesh import, shaders, or a Godot MCP server.

- On Plan send, call the selected model's base URL with its model name. Local and external use the same request shape: an OpenAI-compatible `POST {base}/chat/completions`, bearer token only if that entry has a key. Key stays in `user://`. The test model is already working. Read its base URL and model name from the saved config. Do not hardcode a host.
- Timeout, connection refused, and a non-200 response append the status and body to the job log and mark the job failed. A 503 with a model-load error is a failed job, not a crash. None of these may touch the scene.
- The request tells the model it is planning only. It may describe steps. It must not claim it edited the project.
- Append the model text to the job log. Stage becomes `planned`. The dock shows that text in the job tab.
- Run and Auto-approve still only record the mode. They must not call the model and must not edit the scene. Status line says those modes are not executing yet.
- If the selected model has an empty base URL, send reports that and writes nothing.
- Add a headless check beside `verify_phase1.gd` that loads config, asserts a Plan job can be built, and does not instance a scene-editing class. Do not require a live model in the headless check.
- One live check, editor or a small script: Plan against the saved test model, then confirm the reopened job log contains the model text and no scene file changed.

Done when: Plan against the working test model returns that model's text into the reopened job tab, a bad base URL fails the job without a scene change, and Run / Auto-approve still do not execute.

Keep GDScript typed where Godot 4.7 allows it. No new autoloads.
