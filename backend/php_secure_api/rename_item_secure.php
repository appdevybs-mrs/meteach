<?php
declare(strict_types=1);

require_once __DIR__ . '/file_ops.php';

require_auth(['admin', 'teacher']);

$root = (string) ($_POST['root'] ?? '');
$path = (string) ($_POST['path'] ?? '');
$newName = sanitize_segment((string) ($_POST['new_name'] ?? ''));

if ($newName === '') {
    json_response(['success' => false, 'message' => 'new_name is required.'], 400);
}

$from = resolve_target_path($root, $path);
if (!file_exists($from['full'])) {
    json_response(['success' => false, 'message' => 'Item not found.'], 404);
}

$parent = dirname($from['clean']);
$toRel = ($parent === '.' || $parent === '') ? $newName : ($parent . '/' . $newName);
$to = resolve_target_path($root, $toRel);

ensure_parent_dir(dirname($to['full']));
if (!rename($from['full'], $to['full'])) {
    json_response(['success' => false, 'message' => 'Rename failed.'], 500);
}

json_response(['success' => true]);
