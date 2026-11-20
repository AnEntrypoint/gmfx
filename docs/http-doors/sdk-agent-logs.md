# GET /api/sdk/v1/{worldId}/agent/logs

- Method: GET
- Path: /api/sdk/v1/{worldId}/agent/logs
- URL: https://www.spawn.co/api/sdk/v1/{worldId}/agent/logs
- Auth: required (Authorization: Bearer)
- Status with Bearer: 200 (3869 bytes)
- Status without auth: 401, body `{"error":"Missing authorization header","signup":"https://www.spawn.co/api/agent/v1/signup","docs":"https://www.spawn.co/llms.txt"}`
- Top-level keys (200): cursor, execLogs, liveRooms
- Source: llms.txt says it is "the room's script log, errors naming your paths".
