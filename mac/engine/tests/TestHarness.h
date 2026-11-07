// This file is part of Whorld for macOS, a port of Whorld by Chris Korda.
// Copyleft 2025 Chris Korda (original Whorld); port Copyright 2026 Jeff Matson.
// Written with Claude (Anthropic).
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See the LICENSE file at the repository root.

#pragma once

// Minimal test harness (no third-party dependency). Usage:
//   TEST(name) { CHECK(cond); CHECK_EQ(a, b); CHECK_NEAR(a, b, tol); }
//   int main() { return RunAllTests(); }

#include <cmath>
#include <cstdio>
#include <functional>
#include <sstream>
#include <string>
#include <vector>

namespace whorld_test {

struct TestCase {
	const char* name;
	std::function<void()> fn;
};

inline std::vector<TestCase>& Registry() {
	static std::vector<TestCase> tests;
	return tests;
}

inline int& FailureCount() {
	static int n = 0;
	return n;
}

struct Registrar {
	Registrar(const char* name, std::function<void()> fn) {
		Registry().push_back({name, std::move(fn)});
	}
};

inline void Fail(const char* file, int line, const std::string& msg) {
	std::fprintf(stderr, "%s:%d: FAILED: %s\n", file, line, msg.c_str());
	++FailureCount();
}

template <typename A, typename B>
std::string DescribeNotEqual(const char* ea, const char* eb, const A& a, const B& b) {
	std::ostringstream os;
	os << ea << " == " << eb << " (" << a << " vs " << b << ")";
	return os.str();
}

} // namespace whorld_test

#define WT_CONCAT2(a, b) a##b
#define WT_CONCAT(a, b) WT_CONCAT2(a, b)

#define TEST(name) \
	static void name(); \
	static whorld_test::Registrar WT_CONCAT(reg_, name)(#name, name); \
	static void name()

#define CHECK(cond) \
	do { if (!(cond)) whorld_test::Fail(__FILE__, __LINE__, #cond); } while (0)

#define CHECK_EQ(a, b) \
	do { const auto& wt_a = (a); const auto& wt_b = (b); \
		if (!(wt_a == wt_b)) whorld_test::Fail(__FILE__, __LINE__, \
			whorld_test::DescribeNotEqual(#a, #b, wt_a, wt_b)); } while (0)

#define CHECK_NEAR(a, b, tol) \
	do { double wt_a = (a), wt_b = (b); \
		if (!(std::fabs(wt_a - wt_b) <= (tol))) whorld_test::Fail(__FILE__, __LINE__, \
			whorld_test::DescribeNotEqual(#a, #b, wt_a, wt_b)); } while (0)

inline int RunAllTests() {
	for (const auto& t : whorld_test::Registry()) {
		int before = whorld_test::FailureCount();
		t.fn();
		std::printf("[%s] %s\n", whorld_test::FailureCount() == before ? " OK " : "FAIL", t.name);
	}
	int n = whorld_test::FailureCount();
	std::printf("%zu tests, %d failures\n", whorld_test::Registry().size(), n);
	return n == 0 ? 0 : 1;
}
