using Xunit;
namespace Fixtures.xunit3;
public class ParameterizedTests { [Theory][InlineData(1,2,3)][InlineData(2,3,5)] public void Adds(int a,int b,int expected)=>Assert.Equal(expected,a+b); [Fact] public void ExplicitData()=>Assert.Fail("Expected 1 but got 2"); }
public class DuplicateA { [Fact(DisplayName="same display")] public void SameDisplay(){} }
public class DuplicateB { [Fact(DisplayName="same display")] public void SameDisplay(){} }
public class OutcomeTests { [Fact(Skip="skip")] public void Skipped(){} }
public class UnicodeTests { [Fact] public void Unicode_Δ_雪(){} }
public class LongNameTests { [Fact] public void VeryLongNameSegmentVeryLongNameSegmentVeryLongNameSegmentVeryLongNameSegment(){} }
