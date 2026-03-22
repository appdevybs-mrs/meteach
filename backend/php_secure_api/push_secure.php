<?php
declare(strict_types=1);

require_once __DIR__ . '/bootstrap.php';

$auth = require_auth(['admin', 'teacher']);
$payload = request_json();

$mode = strtolower(trim((string) ($payload['mode'] ?? '')));
$title = mb_substr(trim((string) ($payload['title'] ?? '')), 0, 120);
$message = mb_substr(trim((string) ($payload['message'] ?? '')), 0, 500);
$data = $payload['data'] ?? [];

if ($mode === '' || $title === '' || $message === '') {
    json_response(['success' => false, 'message' => 'Missing mode/title/message.'], 400);
}
if (!is_array($data)) {
    $data = [];
}

$safeData = [];
foreach ($data as $k => $v) {
    $kk = trim((string) $k);
    if ($kk === '') {
        continue;
    }
    $safeData[$kk] = (string) $v;
}

try {
    $messaging = $auth['factory']->createMessaging();
    $cloudMessageClass = 'Kreait\\Firebase\\Messaging\\CloudMessage';
    $notificationClass = 'Kreait\\Firebase\\Messaging\\Notification';

    if ($mode === 'token') {
        $token = trim((string) ($payload['token'] ?? ''));
        if ($token === '') {
            json_response(['success' => false, 'message' => 'Missing token.'], 400);
        }

        $msg = $cloudMessageClass::withTarget('token', $token)
            ->withNotification($notificationClass::create($title, $message))
            ->withData($safeData);

        $messaging->send($msg);
        json_response(['success' => true]);
    }

    if ($mode === 'topic') {
        $topic = trim((string) ($payload['topic'] ?? ''));
        if ($topic === '') {
            json_response(['success' => false, 'message' => 'Missing topic.'], 400);
        }
        if (!preg_match('/^[a-zA-Z0-9_\-\.~%]{1,120}$/', $topic)) {
            json_response(['success' => false, 'message' => 'Invalid topic name.'], 400);
        }

        $msg = $cloudMessageClass::withTarget('topic', $topic)
            ->withNotification($notificationClass::create($title, $message))
            ->withData($safeData);

        $messaging->send($msg);
        json_response(['success' => true]);
    }

    json_response(['success' => false, 'message' => 'Unsupported mode.'], 400);
} catch (Throwable $e) {
    json_response(['success' => false, 'message' => 'Push send failed.'], 500);
}
