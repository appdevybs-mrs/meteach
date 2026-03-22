<?php
declare(strict_types=1);

require_once __DIR__ . '/file_ops.php';

require_auth(['admin', 'teacher']);

function delete_recursive(string $path): bool
{
    if (is_file($path) || is_link($path)) {
        return unlink($path);
    }
    if (!is_dir($path)) {
        return false;
    }

    $items = scandir($path);
    if ($items === false) {
        return false;
    }
    foreach ($items as $item) {
        if ($item === '.' || $item === '..') {
            continue;
        }
        if (!delete_recursive($path . '/' . $item)) {
            return false;
        }
    }
    return rmdir($path);
}

$root = (string) ($_POST['root'] ?? '');
$path = (string) ($_POST['path'] ?? '');
$resolved = resolve_target_path($root, $path);

if (!file_exists($resolved['full'])) {
    json_response(['success' => false, 'message' => 'Item not found.'], 404);
}

if (!delete_recursive($resolved['full'])) {
    json_response(['success' => false, 'message' => 'Delete failed.'], 500);
}

json_response(['success' => true]);
