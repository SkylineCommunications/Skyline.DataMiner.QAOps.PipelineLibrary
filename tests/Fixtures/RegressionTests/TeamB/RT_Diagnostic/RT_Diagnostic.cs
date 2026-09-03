using QAManagement.TestFramework.Attributes;

namespace RegressionTests.TeamB
{
    [DiagnosticTestFixture("RT_Diagnostic", DiagnosticRunType.Before)]
    [NonCentralizedTest]
    [LocalDB]
    public class RT_Diagnostic : TestBase
    {
    }
}
