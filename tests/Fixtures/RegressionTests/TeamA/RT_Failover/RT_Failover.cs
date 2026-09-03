using QAManagement.TestFramework.Attributes;

namespace RegressionTests.TeamA
{
    // A failover fixture using named initialisers and a multi-line attribute list.
    [FailoverTestFixture(
        "RT_Failover",
        true,
        false,
        RunOnNonFailoverSystems = true)]
    [Weight(5)]
    public class RT_Failover : FailoverTestBase
    {
        [BeforeSwitch, Order(1)]
        public void Before() { }

        [AfterSwitch]
        public void After() { }

        [AfterSwitchReInit]
        public void ReInit() { }
    }
}
