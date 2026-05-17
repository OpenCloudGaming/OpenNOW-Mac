#ifndef DOCTEST_H_INCLUDED
#define DOCTEST_H_INCLUDED

#include <cstdio>
#include <cstdlib>
#include <functional>
#include <string>
#include <vector>

namespace doctest {

struct TestCase {
    const char *suite;
    const char *name;
    std::function<void()> function;
};

inline std::vector<TestCase> &testRegistry() {
    static std::vector<TestCase> registry;
    return registry;
}

inline void registerTest(const char *suite, const char *name, const std::function<void()> &function) {
    testRegistry().push_back(TestCase{suite, name, function});
}

inline void fail(const char *file, int line, const char *expr) {
    std::fprintf(stderr, "%s:%d: FAILED: %s\n", file, line, expr);
    std::exit(EXIT_FAILURE);
}

inline void reportSuccess(const char *suite, const char *name) {
    std::printf("[ PASSED ] %s :: %s\n", suite ? suite : "", name);
}

inline int runAllTests() {
    const std::vector<TestCase> &tests = testRegistry();
    for (const TestCase &test : tests) {
        test.function();
        reportSuccess(test.suite ? test.suite : "", test.name ? test.name : "");
    }
    std::printf("\n%d test(s) passed.\n", static_cast<int>(tests.size()));
    return EXIT_SUCCESS;
}

struct TestRegistrar {
    TestRegistrar(const char *suite, const char *name, const std::function<void()> &function) {
        registerTest(suite, name, function);
    }
};

}

#define DOCTEST_CONCAT_INNER(x, y) x##y
#define DOCTEST_CONCAT(x, y) DOCTEST_CONCAT_INNER(x, y)

#define TEST_SUITE(name) static const char *DOCTEST_CURRENT_SUITE = name;
#define TEST_CASE(name) \
    static void DOCTEST_CONCAT(DOCTEST_TEST_FUNC_, __LINE__)(); \
    static doctest::TestRegistrar DOCTEST_CONCAT(DOCTEST_REG_, __LINE__)(DOCTEST_CURRENT_SUITE, name, DOCTEST_CONCAT(DOCTEST_TEST_FUNC_, __LINE__)); \
    static void DOCTEST_CONCAT(DOCTEST_TEST_FUNC_, __LINE__)()

#define CHECK(expr) do { if (!(expr)) doctest::fail(__FILE__, __LINE__, #expr); } while (false)
#define REQUIRE(expr) CHECK(expr)
#define CHECK_EQ(a, b) CHECK((a) == (b))
#define REQUIRE_EQ(a, b) CHECK_EQ((a), (b))

#ifdef DOCTEST_CONFIG_IMPLEMENT_WITH_MAIN
int main() {
    return doctest::runAllTests();
}
#endif

#endif // DOCTEST_H_INCLUDED
