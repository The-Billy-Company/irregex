//! Tests for language-free ranking geometry and generated-artifact evidence.
//! Real regressions from Billy, ripgrep, OpenClaw, Headroom, and OpenHuman are
//! represented by syntax shape rather than project or language labels.

const std = @import("std");
const signals = @import("signals.zig");
const expect = std.testing.expect;

test "declaration confidence follows geometry across syntax families" {
    const confidence = signals.declarationConfidence;
    try expect(confidence("func NewWallet(cc grpc.ClientConn) Wallet {", "NewWallet") == 3);
    try expect(confidence("pub fn parse(self: *T) !void {", "parse") == 3);
    try expect(confidence("def charge(self, amount):", "charge") == 3);
    try expect(confidence("class WalletService:", "WalletService") == 3);
    try expect(confidence("function getWallet() {", "getWallet") == 3);
    try expect(confidence("type Wallet struct {", "Wallet") == 3);
    try expect(confidence("interface WalletService {", "WalletService") == 3);
    try expect(confidence("defmodule Wallet do", "Wallet") == 1); // word-delimited, punctuation-free declaration
    try expect(confidence("def deadline_ms(:scope), do: fetch(:scope)", "deadline_ms") == 3);
    try expect(confidence("const OpenhumanLinkModal = () => {", "OpenhumanLinkModal") == 3);
    try expect(confidence("    const MaxRetries = 5", "MaxRetries") == 3);
    try expect(confidence("func (s *Service) Charge(amount int64) error {", "Charge") == 3); // balanced receiver
    try expect(confidence("let normalizeExecHost: typeof import('./x').normalizeExecHost;", "normalizeExecHost") == 1);
    try expect(confidence("normalizeExecHost = execApprovals.normalizeExecHost;", "normalizeExecHost") == 1);
}

test "declaration geometry is Unicode and notation agnostic" {
    const confidence = signals.declarationConfidence;
    try expect(confidence("public class Καφές {", "Καφές") == 3); // Unicode Java identifier
    try expect(confidence("函数 计算(参数) {", "计算") == 3); // unfamiliar keyword vocabulary
    try expect(confidence("vector_add:", "vector_add") == 3); // assembly label
    try expect(confidence("(defn transform [x] (* x x))", "transform") == 2); // prefix form
    try expect(confidence("(define (transform x) (* x x))", "transform") == 2); // nested prefix form
    try expect(confidence("transform x = x + 1", "transform") == 3); // equational definition
    try expect(confidence("start() -> ok.", "start") == 3); // symbolic body
    try expect(confidence("ancestor(X, Y) :- parent(X, Y).", "ancestor") == 3); // rule head
    try expect(confidence(": square dup * ;", "square") == 3); // delimiter-wrapped definition
    try expect(!signals.definesNeedle("public class Καφéteria {", "Καφé")); // Unicode word boundary
}

test "invalid UTF-8 fails closed around textual symbol geometry" {
    const line = [_]u8{ 0xff, ' ', 'e', 'n', 't', 'r', 'y', ':' };
    try expect(signals.declarationConfidence(&line, "entry") == 3);
    try expect(signals.shapeFingerprint(&line, "entry") != 0);
}

test "declaration geometry rejects parameters, imports, uses, and fragments" {
    try expect(!signals.definesNeedle("    w := NewWallet(cc)", "NewWallet")); // call site
    try expect(!signals.definesNeedle("    return charge(amount)", "charge")); // call site
    try expect(!signals.definesNeedle("    var x = WalletService", "WalletService")); // RHS of =
    try expect(!signals.definesNeedle("    log(\"WalletService started\")", "WalletService")); // string
    try expect(!signals.definesNeedle("    fields := []T{Wallet, Ledger}", "Wallet")); // list element (comma)
    try expect(!signals.definesNeedle("type WalletServiceImpl struct {", "WalletService")); // mid-identifier
    try expect(!signals.definesNeedle("plain text with charge in it", "charge")); // no def kw
    try expect(!signals.definesNeedle("def verdict(req: SearchRequest) -> bool:", "SearchRequest")); // parameter annotation
    try expect(!signals.definesNeedle("import type { ApiError } from './api';", "ApiError")); // import member
    try expect(!signals.definesNeedle("let back: ApiError = decode(value);", "ApiError")); // type annotation
    try expect(!signals.definesNeedle("result: Result<DirEntry, Error>,", "DirEntry")); // nested generic
    try expect(!signals.definesNeedle("import OpenhumanLinkModal, { EVENT } from './modal';", "OpenhumanLinkModal"));
    try expect(!signals.definesNeedle("RegexMatcherBuilder::new().build()", "RegexMatcherBuilder"));
    try expect(!signals.definesNeedle("@spec deadline_ms(kind()) :: pos_integer()", "deadline_ms"));
    try expect(!signals.definesNeedle("expect(normalizeExecHost(raw)).toBe(expected);", "normalizeExecHost"));
}

test "shape fingerprint erases vocabulary but preserves query role" {
    const a = signals.shapeFingerprint("def workspace_dir() -> Path:", "workspace_dir");
    const b = signals.shapeFingerprint("def cache_home() -> Root:", "cache_home");
    const use = signals.shapeFingerprint("return paths.workspace_dir()", "workspace_dir");
    try expect(a != 0);
    try expect(a == b);
    try expect(a != use);
    try expect(signals.shapeFingerprint("class Καφές {", "Καφές") ==
        signals.shapeFingerprint("class Résumé {", "Résumé"));
}

test "isGenerated by ecosystem suffix" {
    const empty = "";
    try expect(signals.isGenerated("services/api/wallet.pb.go", empty)); // Go protobuf
    try expect(signals.isGenerated("x/wallet_pb2.py", empty)); // Python protobuf
    try expect(signals.isGenerated("x/wallet_pb2_grpc.py", empty)); // Python grpc
    try expect(signals.isGenerated("x/Wallet.pb.cc", empty)); // C++ protobuf
    try expect(signals.isGenerated("x/wallet.g.dart", empty)); // Dart codegen
    try expect(signals.isGenerated("x/Wallet.designer.cs", empty)); // C# designer
    try expect(signals.isGenerated("x/app.min.js", empty)); // minified
    try expect(!signals.isGenerated("services/api/wallet.go", empty)); // hand-written
    try expect(!signals.isGenerated("services/api/handler.py", empty));
}

test "isGenerated by universal first-line marker (language-independent)" {
    try expect(signals.isGenerated("a.go", "// Code generated by protoc. DO NOT EDIT.\npackage x\n"));
    try expect(signals.isGenerated("a.py", "# Generated by the protocol buffer compiler.\nimport x\n"));
    try expect(signals.isGenerated("a.ts", "/* @generated */\nexport {}\n"));
    try expect(signals.isGenerated("a.rs", "// AUTO-GENERATED FILE, DO NOT EDIT\n"));
    try expect(signals.isGenerated("a.sql", "-- Autogenerated migration\n"));
    try expect(signals.isGenerated("a.go", "// Copyright holder\n// CODE GENERATED by tool\npackage x\n"));
    // Explanatory prose and a body mention must not trip the header detector.
    try expect(!signals.isGenerated("a.go", "// this discusses Code generated files\npackage x\n"));
    try expect(!signals.isGenerated("a.go", "package x\n// this discusses Code generated files\n"));
    try expect(!signals.isGenerated("a.go", "package main\nfunc main() {}\n"));
}
