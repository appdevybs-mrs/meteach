<?php
declare(strict_types=1);

require_once __DIR__ . '/file_ops.php';

require_auth(['admin', 'teacher']);

$root = (string) ($_POST['root'] ?? '');
$path = (string) ($_POST['path'] ?? '');
$resolved = resolve_target_path($root, $path);

if (!is_dir($resolved['full'])) {
    json_response(['success' => true, 'items' => []]);
}

$entries = scandir($resolved['full']);
if ($entries === false) {
    json_response(['success' => false, 'message' => 'Cannot list directory.'], 500);
}

$items = [];
foreach ($entries as $name) {
    if ($name === '.' || $name === '..') {
        continue;
    }
    $full = $resolved['full'] . '/' . $name;
    $isDir = is_dir($full);
    $items[] = [
        'name' => $name,
        'type' => $isDir ? 'folder' : 'file',
        'size' => $isDir ? 0 : (int) (filesize($full) ?: 0),
        'updatedAt' => (int) (filemtime($full) ?: time()),
    ];
}

json_response(['success' => true, 'items' => $items]);
