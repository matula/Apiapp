import Foundation

/// What `tools/list` tells the client: each tool's name, purpose and JSON Schema input.
extension LibraryTools {
    static let definitions: [JSONValue] = [listLibrary, getRequest, saveRequest, createFolder, saveEnvironment]

    private static let noArguments: JSONValue = ["type": "object", "properties": [:], "additionalProperties": false]

    private static let listLibrary: JSONValue = [
        "name": "list_library",
        "title": "List Apiapp library",
        "description": """
            Lists Apiapp's folders, saved requests (id, name, method, URL and folder) and environments \
            with their variables. Secret variables show without their values.
            """,
        "inputSchema": noArguments,
        "annotations": ["readOnlyHint": true],
    ]

    private static let getRequest: JSONValue = [
        "name": "get_request",
        "title": "Get saved request",
        "description": """
            Shows everything about one saved request, in the shape save_request takes. Pass its id, \
            or its name when only one request has it.
            """,
        "inputSchema": [
            "type": "object",
            "properties": [
                "id": ["type": "string", "description": "The request's id, from list_library."],
                "name": ["type": "string", "description": "The request's name, ignoring case."],
            ],
            "additionalProperties": false,
        ],
        "annotations": ["readOnlyHint": true],
    ]

    private static let saveRequestProperties: JSONValue = [
        "id": ["type": "string", "description": "Update this saved request. Leave it out to create a new one."],
        "name": ["type": "string", "description": "Shown in the sidebar. Needed for a new request."],
        "method": ["type": "string", "enum": ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"]],
        "url": [
            "type": "string",
            "description": "Needed for a new request. May hold a query string and {{variables}}, such as {{baseUrl}}/auth/login.",
        ],
        "folder": [
            "type": "string",
            "description": "A folder's name or id. A name with no folder yet makes one. An empty string means the main list.",
        ],
        "headers": rows("Replaces every header. A Content-Type matching bodyType is added unless one is given here."),
        "bodyType": [
            "type": "string",
            "enum": ["json", "form", "multipart", "raw", "none"],
            "description": "For a new request, json when body is given, otherwise picked from the fields given and the method.",
        ],
        "body": [
            "type": "string",
            "description": "Body text for json or raw. {{variables}} work here, even unquoted in JSON. Give JSON as a string to keep its key order.",
        ],
        "formFields": rows("Fields for bodyType form."),
        "multipartFields": [
            "type": "array",
            "description": "Fields for bodyType multipart. A file field's value is a path on this Mac.",
            "items": [
                "type": "object",
                "properties": [
                    "key": ["type": "string"],
                    "value": ["type": "string"],
                    "kind": ["type": "string", "enum": ["text", "file"]],
                    "enabled": ["type": "boolean"],
                ],
                "required": ["key", "value"],
                "additionalProperties": false,
            ],
        ],
        "auth": [
            "type": "object",
            "description": "token, password and apiKeyValue must be {{variable}} references; real secrets are refused.",
            "properties": [
                "kind": ["type": "string", "enum": ["none", "bearer", "basic", "apiKey"]],
                "token": ["type": "string"],
                "username": ["type": "string"],
                "password": ["type": "string"],
                "apiKeyName": ["type": "string", "description": "Defaults to X-API-Key."],
                "apiKeyValue": ["type": "string"],
                "apiKeyPlacement": ["type": "string", "enum": ["header", "query"]],
            ],
            "required": ["kind"],
            "additionalProperties": false,
        ],
    ]

    private static let saveRequest: JSONValue = [
        "name": "save_request",
        "title": "Save request",
        "description": """
            Saves a request in Apiapp, where it shows in the sidebar. Without an id it makes a new request; \
            with one it changes only the fields given. Use {{variables}} for anything that differs between \
            environments, and for every password, token or key: real secrets are refused, and belong in a \
            secret variable (see save_environment) whose value the user types in Apiapp.
            """,
        "inputSchema": ["type": "object", "properties": saveRequestProperties, "additionalProperties": false],
        "annotations": ["readOnlyHint": false, "destructiveHint": false, "idempotentHint": false],
    ]

    private static let createFolder: JSONValue = [
        "name": "create_folder",
        "title": "Create folder",
        "description": "Makes a folder for saved requests, or returns the one that already has this name.",
        "inputSchema": [
            "type": "object",
            "properties": ["name": ["type": "string"]],
            "required": ["name"],
            "additionalProperties": false,
        ],
        "annotations": ["readOnlyHint": false, "destructiveHint": false, "idempotentHint": true],
    ]

    private static let saveEnvironment: JSONValue = [
        "name": "save_environment",
        "title": "Save environment",
        "description": """
            Makes an environment, or updates the one with this id or name. Variables are matched by key: \
            a new key is added, a known one is updated, and keys not given are left alone. A secret \
            variable's value can't be set here; the user types it in Apiapp, which keeps it in the Keychain.
            """,
        "inputSchema": [
            "type": "object",
            "properties": [
                "id": ["type": "string", "description": "The environment's id, from list_library."],
                "name": ["type": "string", "description": "Finds the environment by name, or names a new one."],
                "variables": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "properties": [
                            "key": ["type": "string", "description": "Used as {{key}} in requests."],
                            "value": ["type": "string", "description": "Leave out for a secret variable."],
                            "secret": ["type": "boolean", "description": "For passwords, tokens and keys."],
                            "enabled": ["type": "boolean"],
                        ],
                        "required": ["key"],
                        "additionalProperties": false,
                    ],
                ],
            ],
            "additionalProperties": false,
        ],
        "annotations": ["readOnlyHint": false, "destructiveHint": false, "idempotentHint": true],
    ]

    private static func rows(_ description: String) -> JSONValue {
        [
            "type": "array",
            "description": .string(description),
            "items": [
                "type": "object",
                "properties": [
                    "key": ["type": "string"],
                    "value": ["type": "string"],
                    "enabled": ["type": "boolean", "description": "Defaults to true."],
                ],
                "required": ["key", "value"],
                "additionalProperties": false,
            ],
        ]
    }
}
