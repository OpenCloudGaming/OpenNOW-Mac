#ifndef DOCTEST_H_INCLUDED
#define DOCTEST_H_INCLUDED

#include <chrono>
#include <cstring>
#include <exception>
#include <cstdio>
#include <cstdlib>
#include <functional>
#include <string>
#include <vector>

namespace doctest {

struct TestCase {
    const char *suite;
    const char *name;
    const char *file;
    int line;
    std::function<void()> function;
};

struct TestResult {
    bool passed;
    const char *file;
    int line;
    std::string message;
    std::string expression;
    double durationSeconds;
};

struct CommandLineOptions {
    bool showHelp = false;
    bool listTestCases = false;
    bool useXmlReporter = false;
    std::string testSuite;
    std::vector<std::string> testCases;
};

class TestFailure final : public std::exception {
public:
    TestFailure(const char *sourceFile, int sourceLine, const char *failedExpression)
        : file(sourceFile), line(sourceLine), expression(failedExpression), description(std::string(sourceFile) + ":" + std::to_string(sourceLine) + ": FAILED: " + failedExpression) {}

    const char *what() const noexcept override {
        return description.c_str();
    }

    const char *file;
    int line;
    std::string expression;

private:
    std::string description;
};

inline std::vector<TestCase> &testRegistry() {
    static std::vector<TestCase> registry;
    return registry;
}

inline void registerTest(const char *suite, const char *name, const char *file, int line, const std::function<void()> &function) {
    testRegistry().push_back(TestCase{suite, name, file, line, function});
}

inline void fail(const char *file, int line, const char *expr) {
    throw TestFailure(file, line, expr);
}

inline void reportSuccess(const char *suite, const char *name) {
    std::printf("[ PASSED ] %s :: %s\n", suite ? suite : "", name);
}

inline void reportFailure(const TestCase &test, const TestResult &result) {
    std::fprintf(stderr, "[ FAILED ] %s :: %s\n", test.suite ? test.suite : "", test.name ? test.name : "");
    std::fprintf(stderr, "%s:%d: %s\n", result.file ? result.file : test.file, result.line, result.message.c_str());
}

inline bool hasPrefix(const std::string &value, const char *prefix) {
    return value.rfind(prefix, 0) == 0;
}

inline std::vector<std::string> splitCommaSeparated(const std::string &value) {
    std::vector<std::string> parts;
    std::string current;
    for (char character : value) {
        if (character == ',') {
            parts.push_back(current);
            current.clear();
        } else {
            current.push_back(character == '?' ? ',' : character);
        }
    }
    parts.push_back(current);
    return parts;
}

inline CommandLineOptions parseCommandLine(int argc, char **argv) {
    CommandLineOptions options;
    for (int index = 1; index < argc; ++index) {
        const std::string argument(argv[index]);
        if (argument == "--help" || argument == "-h") {
            options.showHelp = true;
        } else if (argument == "--list-test-cases" || argument == "--ltc") {
            options.listTestCases = true;
        } else if (argument == "--reporters=xml" || argument == "--reporter=xml") {
            options.useXmlReporter = true;
        } else if (hasPrefix(argument, "--test-suite=")) {
            options.testSuite = argument.substr(std::strlen("--test-suite="));
        } else if (argument == "--test-suite" && index + 1 < argc) {
            options.testSuite = argv[++index];
        } else if (hasPrefix(argument, "--test-case=")) {
            options.testCases = splitCommaSeparated(argument.substr(std::strlen("--test-case=")));
        } else if (argument == "--test-case" && index + 1 < argc) {
            options.testCases = splitCommaSeparated(argv[++index]);
        }
    }
    return options;
}

inline std::string xmlEscape(const std::string &value) {
    std::string escaped;
    escaped.reserve(value.size());
    for (char character : value) {
        switch (character) {
        case '&':
            escaped += "&amp;";
            break;
        case '<':
            escaped += "&lt;";
            break;
        case '>':
            escaped += "&gt;";
            break;
        case '"':
            escaped += "&quot;";
            break;
        case '\'':
            escaped += "&apos;";
            break;
        default:
            escaped.push_back(character);
            break;
        }
    }
    return escaped;
}

inline bool matchesRequestedTests(const TestCase &test, const CommandLineOptions &options) {
    if (!options.testSuite.empty() && options.testSuite != (test.suite ? test.suite : "")) {
        return false;
    }
    if (options.testCases.empty()) {
        return true;
    }
    for (const std::string &testName : options.testCases) {
        if (testName == (test.name ? test.name : "")) {
            return true;
        }
    }
    return false;
}

inline TestResult runSingleTest(const TestCase &test) {
    const auto start = std::chrono::steady_clock::now();
    try {
        test.function();
        const auto end = std::chrono::steady_clock::now();
        return TestResult{true, test.file, test.line, "", "", std::chrono::duration<double>(end - start).count()};
    } catch (const TestFailure &failure) {
        const auto end = std::chrono::steady_clock::now();
        return TestResult{false, failure.file, failure.line, failure.what(), failure.expression, std::chrono::duration<double>(end - start).count()};
    } catch (const std::exception &exception) {
        const auto end = std::chrono::steady_clock::now();
        return TestResult{false, test.file, test.line, exception.what(), "", std::chrono::duration<double>(end - start).count()};
    } catch (...) {
        const auto end = std::chrono::steady_clock::now();
        return TestResult{false, test.file, test.line, "unknown exception", "", std::chrono::duration<double>(end - start).count()};
    }
}

inline void printHelp() {
    std::printf("[doctest] doctest version is \"2.4.11\"\n");
    std::printf("Usage: backend_tests [doctest options]\n\n");
    std::printf(" --list-test-cases     list all test cases\n");
    std::printf(" --test-suite=<name>   filter by test suite\n");
    std::printf(" --test-case=<name>    filter by test case\n");
    std::printf(" --reporters=xml       write doctest-compatible XML\n");
}

inline void listTestsAsXml(const CommandLineOptions &options) {
    std::printf("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n");
    std::printf("<doctest>\n");
    for (const TestCase &test : testRegistry()) {
        if (!matchesRequestedTests(test, options)) {
            continue;
        }
        std::printf("  <TestCase name=\"%s\" testsuite=\"%s\" filename=\"%s\" line=\"%d\"/>\n",
                    xmlEscape(test.name ? test.name : "").c_str(),
                    xmlEscape(test.suite ? test.suite : "").c_str(),
                    xmlEscape(test.file ? test.file : "").c_str(),
                    test.line);
    }
    std::printf("</doctest>\n");
}

inline void listTestsAsText(const CommandLineOptions &options) {
    for (const TestCase &test : testRegistry()) {
        if (matchesRequestedTests(test, options)) {
            std::printf("%s\n", test.name ? test.name : "");
        }
    }
}

inline void printXmlTestResult(const TestCase &test, const TestResult &result) {
    std::printf("    <TestCase name=\"%s\" filename=\"%s\" line=\"%d\" skipped=\"false\">\n",
                xmlEscape(test.name ? test.name : "").c_str(),
                xmlEscape(test.file ? test.file : "").c_str(),
                test.line);
    if (!result.passed && !result.expression.empty()) {
        std::printf("      <Expression success=\"false\" type=\"CHECK\" filename=\"%s\" line=\"%d\">\n",
                    xmlEscape(result.file ? result.file : test.file).c_str(),
                    result.line);
        std::printf("        <Original>%s</Original>\n", xmlEscape(result.expression).c_str());
        std::printf("        <Expanded>%s</Expanded>\n", xmlEscape(result.expression).c_str());
        std::printf("      </Expression>\n");
    } else if (!result.passed) {
        std::printf("      <Exception crash=\"false\" filename=\"%s\" line=\"%d\">%s</Exception>\n",
                    xmlEscape(result.file ? result.file : test.file).c_str(),
                    result.line,
                    xmlEscape(result.message).c_str());
    }
    std::printf("      <OverallResultsAsserts successes=\"%d\" failures=\"%d\" test_case_success=\"%s\" duration=\"%.9f\"/>\n",
                result.passed ? 1 : 0,
                result.passed ? 0 : 1,
                result.passed ? "true" : "false",
                result.durationSeconds);
    std::printf("    </TestCase>\n");
}

inline int runTestsAsXml(const CommandLineOptions &options) {
    int failures = 0;
    const char *openSuite = nullptr;
    std::printf("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n");
    std::printf("<doctest>\n");
    std::printf("  <Options rand_seed=\"0\"/>\n");
    const std::vector<TestCase> &tests = testRegistry();
    for (const TestCase &test : tests) {
        if (!matchesRequestedTests(test, options)) {
            continue;
        }
        if (openSuite == nullptr || std::strcmp(openSuite, test.suite ? test.suite : "") != 0) {
            if (openSuite != nullptr) {
                std::printf("  </TestSuite>\n");
            }
            openSuite = test.suite ? test.suite : "";
            std::printf("  <TestSuite name=\"%s\">\n", xmlEscape(openSuite).c_str());
        }
        const TestResult result = runSingleTest(test);
        if (!result.passed) {
            ++failures;
        }
        printXmlTestResult(test, result);
    }
    if (openSuite != nullptr) {
        std::printf("  </TestSuite>\n");
    }
    std::printf("</doctest>\n");
    return failures == 0 ? EXIT_SUCCESS : EXIT_FAILURE;
}

inline int runTestsAsText(const CommandLineOptions &options) {
    int passed = 0;
    int failed = 0;
    const std::vector<TestCase> &tests = testRegistry();
    for (const TestCase &test : tests) {
        if (!matchesRequestedTests(test, options)) {
            continue;
        }
        const TestResult result = runSingleTest(test);
        if (result.passed) {
            ++passed;
            reportSuccess(test.suite ? test.suite : "", test.name ? test.name : "");
        } else {
            ++failed;
            reportFailure(test, result);
        }
    }
    if (failed == 0) {
        std::printf("\n%d test(s) passed.\n", passed);
    } else {
        std::fprintf(stderr, "\n%d test(s) passed, %d test(s) failed.\n", passed, failed);
    }
    return failed == 0 ? EXIT_SUCCESS : EXIT_FAILURE;
}

inline int runAllTests(int argc, char **argv) {
    const CommandLineOptions options = parseCommandLine(argc, argv);
    if (options.showHelp) {
        printHelp();
        return EXIT_SUCCESS;
    }
    if (options.listTestCases) {
        if (options.useXmlReporter) {
            listTestsAsXml(options);
        } else {
            listTestsAsText(options);
        }
        return EXIT_SUCCESS;
    }
    return options.useXmlReporter ? runTestsAsXml(options) : runTestsAsText(options);
}

struct TestRegistrar {
    TestRegistrar(const char *suite, const char *name, const char *file, int line, const std::function<void()> &function) {
        registerTest(suite, name, file, line, function);
    }
};

}

#define DOCTEST_CONCAT_INNER(x, y) x##y
#define DOCTEST_CONCAT(x, y) DOCTEST_CONCAT_INNER(x, y)

#define TEST_SUITE(name) static const char *DOCTEST_CURRENT_SUITE = name;
#define TEST_CASE(name) \
    static void DOCTEST_CONCAT(DOCTEST_TEST_FUNC_, __LINE__)(); \
    static doctest::TestRegistrar DOCTEST_CONCAT(DOCTEST_REG_, __LINE__)(DOCTEST_CURRENT_SUITE, name, __FILE__, __LINE__, DOCTEST_CONCAT(DOCTEST_TEST_FUNC_, __LINE__)); \
    static void DOCTEST_CONCAT(DOCTEST_TEST_FUNC_, __LINE__)()

#define CHECK(expr) do { if (!(expr)) doctest::fail(__FILE__, __LINE__, #expr); } while (false)
#define REQUIRE(expr) CHECK(expr)
#define CHECK_EQ(a, b) CHECK((a) == (b))
#define REQUIRE_EQ(a, b) CHECK_EQ((a), (b))

#ifdef DOCTEST_CONFIG_IMPLEMENT_WITH_MAIN
int main(int argc, char **argv) {
    return doctest::runAllTests(argc, argv);
}
#endif

#endif // DOCTEST_H_INCLUDED
