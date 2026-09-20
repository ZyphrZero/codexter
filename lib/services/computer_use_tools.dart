const computerUseMcpName = 'computer-use';
const computerUseMcpDisplayName = 'Computer Use';
const computerUseMcpDescription =
    'Windows desktop interaction, accessibility inspection and screenshots. After completing the current desktop task, call end_turn once as the final Computer Use action.';

const Map<String, dynamic> _windowSchema = {
  'type': 'object',
  'description':
      'A window object returned by list_apps, list_windows, get_window, or get_window_state.',
  'properties': {
    'app': {'type': 'string', 'description': 'Application identifier returned by Computer Use.'},
    'id': {'type': 'integer', 'description': 'Opaque window identifier.'},
    'title': {'type': 'string', 'description': 'User-visible window title when available.'},
  },
  'required': ['app', 'id'],
};

const List<Map<String, dynamic>> computerUseToolDefinitions = [
  {
    'name': 'list_windows',
    'description':
        'Lists currently open Windows application windows and returns window objects for subsequent interaction.',
    'inputSchema': {'type': 'object', 'properties': <String, dynamic>{}},
    'annotations': {'readOnlyHint': true, 'destructiveHint': false, 'openWorldHint': false},
  },
  {
    'name': 'get_window',
    'description':
        'Rehydrate a currently open window by its opaque id and optional app identifier. Use ids returned by Computer Use; do not guess window ids.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'id': {
          'type': 'integer',
          'minimum': 0,
          'description': 'Window id returned by Computer Use.',
        },
        'app': {
          'type': 'string',
          'description': 'Optional app identifier from the returned Window.',
        },
      },
      'required': ['id'],
    },
    'annotations': {'readOnlyHint': true, 'destructiveHint': false, 'openWorldHint': false},
  },
  {
    'name': 'list_apps',
    'description':
        'List installed/discoverable Windows apps and their currently open targetable windows. Use the returned app id with launch_app and returned windows for later actions.',
    'inputSchema': {'type': 'object', 'properties': <String, dynamic>{}},
    'annotations': {'readOnlyHint': true, 'destructiveHint': false, 'openWorldHint': false},
  },
  {
    'name': 'launch_app',
    'description':
        'Launch a Windows application by an app id returned from list_apps, or by an explicit executable identifier supported by the installed Computer Use runtime. Refresh list_apps/list_windows afterwards.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'app': {'type': 'string', 'description': 'App identifier to launch.'},
      },
      'required': ['app'],
    },
    'annotations': {'readOnlyHint': false, 'destructiveHint': false, 'openWorldHint': true},
  },
  {
    'name': 'get_window_state',
    'description':
        'Capture point-in-time state for one target window. Can return a screenshot and/or Accessibility Tree text. Element indexes are observation-scoped. Screenshot ids are valid only for the latest screenshot observation globally: any later get_window_state screenshot, even for another window, invalidates earlier screenshot ids.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'window': _windowSchema,
        'include_screenshot': {
          'type': 'boolean',
          'description': 'Capture a screenshot. Defaults to true.',
          'default': true,
        },
        'include_text': {
          'type': 'boolean',
          'description': 'Capture accessibility text/tree and element indexes. Defaults to false.',
          'default': false,
        },
      },
      'required': ['window'],
    },
    'annotations': {'readOnlyHint': true, 'destructiveHint': false, 'openWorldHint': false},
  },
  {
    'name': 'click',
    'description':
        'Click inside a target window. Prefer element_index from the latest accessibility observation; otherwise use window-relative x/y coordinates and pass screenshotId from the matching latest screenshot observation.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'window': _windowSchema,
        'element_index': {
          'type': 'integer',
          'minimum': 0,
          'description': 'Accessibility element index.',
        },
        'x': {'type': 'number', 'description': 'Window-relative X coordinate.'},
        'y': {'type': 'number', 'description': 'Window-relative Y coordinate.'},
        'screenshotId': {
          'type': 'string',
          'description':
              'Screenshot id from the latest get_window_state screenshot. A later screenshot of any window invalidates it.',
        },
        'click_count': {'type': 'integer', 'minimum': 1, 'default': 1},
        'mouse_button': {
          'type': 'string',
          'enum': ['left', 'right', 'middle', 'l', 'r', 'm'],
          'default': 'left',
        },
      },
      'required': ['window'],
    },
    'annotations': {'readOnlyHint': false, 'destructiveHint': false, 'openWorldHint': true},
  },
  {
    'name': 'press_key',
    'description':
        'Send a key or + separated key chord to a target window, for example Return, Tab, Control_L+a, or Control_L+Shift_L+period. Use this for control keys instead of embedding control characters in text.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'window': _windowSchema,
        'key': {'type': 'string', 'description': 'Key name or + separated key chord.'},
      },
      'required': ['window', 'key'],
    },
    'annotations': {'readOnlyHint': false, 'destructiveHint': false, 'openWorldHint': true},
  },
  {
    'name': 'type_text',
    'description':
        'Type literal text into the current focus of a target window. Verify the focused element with fresh window state before typing into editors, forms, documents, or other sensitive destinations.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'window': _windowSchema,
        'text': {'type': 'string', 'description': 'Literal text to type.'},
      },
      'required': ['window', 'text'],
    },
    'annotations': {'readOnlyHint': false, 'destructiveHint': false, 'openWorldHint': true},
  },
  {
    'name': 'scroll',
    'description':
        'Scroll a target window from a window-relative coordinate. Positive scrollY scrolls down and negative scrollY scrolls up; pass the latest matching screenshotId when available.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'window': _windowSchema,
        'x': {'type': 'number', 'description': 'Window-relative X coordinate.'},
        'y': {'type': 'number', 'description': 'Window-relative Y coordinate.'},
        'scrollX': {'type': 'number', 'description': 'Horizontal scroll delta.'},
        'scrollY': {'type': 'number', 'description': 'Vertical scroll delta.'},
        'screenshotId': {
          'type': 'string',
          'description':
              'Screenshot id from the latest get_window_state screenshot. A later screenshot of any window invalidates it.',
        },
      },
      'required': ['window', 'x', 'y', 'scrollX', 'scrollY'],
    },
    'annotations': {'readOnlyHint': false, 'destructiveHint': false, 'openWorldHint': true},
  },
  {
    'name': 'set_value',
    'description':
        'Replace the value of an editable accessibility element using an element_index from the latest accessibility observation. Refresh window state after the action.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'window': _windowSchema,
        'element_index': {
          'type': 'integer',
          'minimum': 0,
          'description': 'Accessibility element index.',
        },
        'value': {'type': 'string', 'description': 'Replacement value.'},
      },
      'required': ['window', 'element_index', 'value'],
    },
    'annotations': {'readOnlyHint': false, 'destructiveHint': false, 'openWorldHint': true},
  },
  {
    'name': 'drag',
    'description':
        'Drag from one window-relative coordinate to another in a target window. Use coordinates from the latest screenshot and pass its screenshotId when available.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'window': _windowSchema,
        'from_x': {'type': 'number'},
        'from_y': {'type': 'number'},
        'to_x': {'type': 'number'},
        'to_y': {'type': 'number'},
        'screenshotId': {
          'type': 'string',
          'description':
              'Screenshot id from the latest get_window_state screenshot. A later screenshot of any window invalidates it.',
        },
      },
      'required': ['window', 'from_x', 'from_y', 'to_x', 'to_y'],
    },
    'annotations': {'readOnlyHint': false, 'destructiveHint': false, 'openWorldHint': true},
  },
  {
    'name': 'perform_secondary_action',
    'description':
        'Invoke a secondary accessibility action on an element from the latest accessibility state, such as Raise, Expand, Collapse, Scroll Up, Scroll Down, Scroll Left, or Scroll Right.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'window': _windowSchema,
        'element_index': {'type': 'integer', 'minimum': 0},
        'action': {
          'type': 'string',
          'description': 'Secondary action label returned/supported by accessibility.',
        },
      },
      'required': ['window', 'element_index', 'action'],
    },
    'annotations': {'readOnlyHint': false, 'destructiveHint': false, 'openWorldHint': true},
  },
  {
    'name': 'activate_window',
    'description':
        'Bring a target window to the foreground. Use this to recover focus or before retrying an input after another window covered the target.',
    'inputSchema': {
      'type': 'object',
      'properties': {'window': _windowSchema},
      'required': ['window'],
    },
    'annotations': {'readOnlyHint': false, 'destructiveHint': false, 'openWorldHint': true},
  },
  {
    'name': 'end_turn',
    'description':
        'End the current Computer Use interaction without shutting down the reusable helper process. Call this once, and only after all Windows desktop actions for the current user request are complete. It must be the final Computer Use tool call for that user turn.',
    'inputSchema': {'type': 'object', 'properties': <String, dynamic>{}},
    'annotations': {'readOnlyHint': false, 'destructiveHint': false, 'openWorldHint': false},
  },
];

bool isComputerUseTool(String name) {
  return computerUseToolDefinitions.any((tool) => tool['name'] == name);
}
