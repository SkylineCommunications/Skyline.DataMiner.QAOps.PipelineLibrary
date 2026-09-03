using QAManagement.TestFramework.Attributes;

namespace RegressionTests.TeamA
{
    [TestFixture("RT_Full")]
    [Weight(2)]
    [CanRunConcurrently(false)]
    [TargetDMA(RunOn.All)]
    [Keywords("Alarming", "Smoke")]
    [Squad("SquadA", "SquadB")]
    [Maintainers("jdoe")]
    [Customers("Customer, With Comma")]
    [MinVersion("10.1.0.0-CU5", "10.2.0.0", "10.3.0.0")]
    [LocalDB(DBMSType.MySQL, DBMSType.Cassandra)]
    [SolutionInfo(Solution.SRM, "1.2.3")]
    [RedGreenTest]
    [BaselineTest, CentralizedTest]
    [DCPIDS("DCP1", "DCP2")]
    [RNIDS("RN1")]
    [Disabled("")]
    public class RT_Full : TestBase
    {
        [OneTimeSetUp]
        public void Setup() { }
    }
}
