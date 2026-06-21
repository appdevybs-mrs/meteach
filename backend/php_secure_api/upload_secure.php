<?php
declare(strict_types=1);

require_once __DIR__ . '/file_ops.php';

$auth = require_auth(['admin', 'teacher', 'learner', 'oteacher']);

const MAX_UPLOAD_BYTES = 250 * 1024 * 1024;
const ALLOWED_EXTENSIONS = [
    'jpg', 'jpeg', 'png', 'webp', 'gif',
    'mp4', 'm4v', 'mov', 'webm',
    'mp3', 'm4a', 'wav',
    'pdf', 'doc', 'docx', 'ppt', 'pptx', 'xls', 'xlsx', 'txt',
];

if (!isset($_FILES['file']) || !is_array($_FILES['file'])) {
    json_response(['success' => false, 'message' => 'Missing file.'], 400);
}

$appId = sanitize_segment((string) ($_POST['app_id'] ?? 'app_' . $auth['uid']));
if ($appId === '') {
    $appId = 'app_' . $auth['uid'];
}

$todayPath = date('Y/m');
$resolved = resolve_target_path('courses', 'uploads/' . $appId . '/' . $todayPath);
ensure_parent_dir($resolved['full']);

$tmp = (string) ($_FILES['file']['tmp_name'] ?? '');
if ($tmp === '' || !is_uploaded_file($tmp)) {
    json_response(['success' => false, 'message' => 'Invalid upload temp file.'], 400);
}

$size = (int) ($_FILES['file']['size'] ?? 0);
if ($size <= 0 || $size > MAX_UPLOAD_BYTES) {
    json_response(['success' => false, 'message' => 'Invalid file size.'], 400);
}

$origName = (string) ($_FILES['file']['name'] ?? 'file.bin');
$safeName = sanitize_segment(pathinfo($origName, PATHINFO_FILENAME));
$ext = strtolower((string) pathinfo($origName, PATHINFO_EXTENSION));
if ($safeName === '') {
    $safeName = 'file';
}
if ($ext === '' || !in_array($ext, ALLOWED_EXTENSIONS, true)) {
    json_response(['success' => false, 'message' => 'File type not allowed.'], 400);
}

$finalName = $safeName . '_' . bin2hex(random_bytes(6)) . ($ext !== '' ? '.' . $ext : '');
$targetPath = $resolved['full'] . '/' . $finalName;

if (!move_uploaded_file($tmp, $targetPath)) {
    json_response(['success' => false, 'message' => 'Failed to save uploaded file.'], 500);
}

$rel = trim($resolved['clean'] . '/' . $finalName, '/');
$url = build_public_url($resolved['root'], $rel);

$thumbnailUrl = '';
$videoExts = ['mp4', 'm4v', 'mov', 'webm'];
if (in_array($ext, $videoExts, true)) {
    $thumbName = pathinfo($finalName, PATHINFO_FILENAME) . '_thumb.jpg';
    $thumbPath = $resolved['full'] . '/' . $thumbName;
    $ffmpegCmd = sprintf(
        'ffmpeg -y -i %s -ss 00:00:01 -vframes 1 -q:v 3 %s 2>&1',
        escapeshellarg($targetPath),
        escapeshellarg($thumbPath)
    );
    exec($ffmpegCmd, $ffmpegOut, $ffmpegExit);
    if ($ffmpegExit !== 0) {
        error_log('ffmpeg thumbnail failed (exit=' . $ffmpegExit . '): ' . implode("\n", $ffmpegOut));
    }
    if ($ffmpegExit === 0 && file_exists($thumbPath)) {
        $thumbRel = trim($resolved['clean'] . '/' . $thumbName, '/');
        $thumbnailUrl = build_public_url($resolved['root'], $thumbRel);
    }
}

json_response([
    'success' => true,
    'url' => $url,
    'thumbnail_url' => $thumbnailUrl,
    'uploaderUid' => $auth['uid'],
]);
