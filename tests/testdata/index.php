<?php
header('Content-Type: text/plain');
echo 'sapi=', PHP_SAPI, "\n";
echo 'uri=', $_SERVER['REQUEST_URI'] ?? '(missing)', "\n";
