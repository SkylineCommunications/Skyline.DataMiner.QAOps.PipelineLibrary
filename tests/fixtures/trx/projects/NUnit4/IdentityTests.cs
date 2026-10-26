using NUnit.Framework;
namespace Fixtures.nunit4;
public class ParameterizedTests { [TestCase(1,2,3)][TestCase(2,3,5)] public void Adds(int a,int b,int expected)=>Assert.That(a+b, Is.EqualTo(expected)); [Test] public void ExplicitData()=>Assert.Fail("Expected 1 but got 2"); }
public class DuplicateA { [Test] public void SameDisplay(){} }
public class DuplicateB { [Test] public void SameDisplay(){} }
public class OutcomeTests { [Test][Ignore("skip")] public void Skipped(){} }
public class UnicodeTests { [Test] public void Unicode_Δ_雪(){} }
public class LongNameTests { [Test] public void VeryLongNameSegmentVeryLongNameSegmentVeryLongNameSegmentVeryLongNameSegment()=>Assert.Inconclusive("long"); }
