using QAManagement.TestFramework.Attributes;

namespace RegressionTests.TeamB
{
    [PreRunFixture("RT_DisabledNoReason")]
    [Disabled("Broken since DCP1234, see ticket (blocking)")]
    public class RT_DisabledNoReason : TestBase
    {
    }
}
