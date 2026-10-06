using Microsoft.VisualStudio.TestTools.UnitTesting;
namespace Fixtures.mstest3;
[TestClass] public class ParameterizedTests { [DataTestMethod][DataRow(1,2,3)][DataRow(2,3,5)] public void Adds(int a,int b,int expected)=>Assert.AreEqual(expected,a+b); [TestMethod] public void ExplicitData()=>Assert.Fail("Expected 1 but got 2"); }
[TestClass] public class DuplicateA { [TestMethod][DisplayName("same display")] public void SameDisplay(){} }
[TestClass] public class DuplicateB { [TestMethod][DisplayName("same display")] public void SameDisplay(){} }
[TestClass] public class OutcomeTests { [TestMethod][Ignore] public void Skipped(){} }
[TestClass] public class UnicodeTests { [TestMethod] public void Unicode_Δ_雪(){} }
[TestClass] public class LongNameTests { [TestMethod] public void VeryLongNameSegmentVeryLongNameSegmentVeryLongNameSegmentVeryLongNameSegment()=>Assert.Inconclusive("long"); }
